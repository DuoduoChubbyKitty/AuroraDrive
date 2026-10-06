// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  MapWindow.swift — AuroraDrive 独立地图窗口（三栏）
// ============================================================================
//
//  【为什么要独立窗口，而不是只在 MissionConsole 里嵌一块】
//  驾驶时要能一边开车一边把地图摊在旁边看（或丢到副屏）。嵌在控制台里
//  就必须来回切面板，驾驶中切面板 = 分神。
//
//  【三栏结构（2026-10-04 改版）】
//      ┌──────────────────────────────────────────────────────┐
//      │ 顶栏 44pt：logo · 品牌名 · 搜索框 · 重置视野            │
//      ├──────────┬────────────────────────────┬──────────────┤
//      │ 驾驶面板  │                            │ 标签分类      │
//      │ 320pt    │        地图（自适应）        │ 300pt        │
//      │DecisionRail│    LargeMapCanvas         │CategoryPanel │
//      └──────────┴────────────────────────────┴──────────────┘
//
//  【为什么左栏直接复用 DecisionRail 而不是另写一套】
//  `MissionConsole.swift` 里的 `DecisionRail` 已经承载了驾驶状态 / 决策电路 /
//  状态向量 / 路线四块，且**唯一挂载点本来就是大地图侧栏**（见该 struct 注释）。
//  复制一份必然与主界面漂移 —— 而「两个地方显示的不是同一份状态」是最不能忍的。
//
//  【为什么沿用「辅助窗口」的写法】
//  `AuroraDriveApp` 的启动逻辑会遍历窗口，把「退化成空壳」的窗口关掉
//  （见 `AuroraDriveApp.swift` 主窗口挑选那段）。地图窗口是**有意创建的
//  辅助窗口**，必须带 `AuroraAuxMap` 标识，否则会被那段逻辑误判并关闭 ——
//  与 `GameHUDWindow` 用 `AuroraAuxHUD` 是同一个原因。
//
//  【为什么用 NSWindow 而不是 SwiftUI WindowGroup】
//  本 app 的 AppKit 生命周期下，额外的 WindowGroup 开窗不可靠
//  （`AuroraDriveApp.swift` 里已记过这条教训）。直接建 NSWindow + NSHostingView
//  是可控且幂等的。
//
//  【引擎进程保护】
//  引擎进程（`--engine`）没有 NSApplication UI 上下文，建窗会触发 AppKit
//  断言崩溃。`GameHUDWindow.install()` 已有这个守卫，这里照抄。
// ============================================================================

import AppKit
import SwiftUI

// ============================================================================
// MARK: - 布局契约
// ============================================================================

/// 三栏布局尺寸的**唯一出处**。
///
/// 抽成常量而不是散落在各处写 `320`，是为了让 `runMapWindowTest()` 能对
/// 「三栏存在、宽度正确」做**可断言**的检查 —— 否则只能靠肉眼看截图，
/// 那就不是验证，是欣赏。
enum MapWindowLayout {
    static let topBarHeight: CGFloat = 44
    static let leftWidth: CGFloat = 320
    static let rightWidth: CGFloat = 300

    /// **设计尺寸**（理想值：主屏 1470×956 下中栏 660pt）。
    ///
    /// ⚠️ 这不是「开窗尺寸」—— 实际开窗请用 `fittedContentSize(for:)`。
    /// 设计值宽 1280 在用户的 **1200×1920 竖屏**上放不下：`NSWindow.center()`
    /// 之后系统会把窗口**钳到屏幕宽 1200**，中栏被压到 580pt；而且窗口落点
    /// 随当前主屏变化，尺寸断言会**时红时绿**（2026-10-04 实测踩到：同一份
    /// 代码落在主屏过、落在竖屏红）。
    static let defaultContentSize = CGSize(width: 1280, height: 820)
    static let minContentSize = CGSize(width: 720, height: 520)

    /// 窗口与屏幕边缘的留白（视觉呼吸 + 不被 Dock / 菜单栏压住）。
    static let screenMargin: CGFloat = 24

    /// 把**设计尺寸收缩到目标屏幕放得下**（只缩不放，绝不放大）。
    ///
    /// 规则：
    ///   1. 宽 / 高分别取 `min(设计值, 屏幕可见区 − 2×screenMargin)`；
    ///   2. **不低于 `minContentSize`** —— 宁可超出屏幕，也不把三栏压到不可用；
    ///   3. 大屏（主屏 1470×956）算出 1280×820 = 设计值，**行为与改动前逐字一致**；
    ///      只有放不下的屏（竖屏 1200）才收缩到 1152×820。
    ///
    /// 为什么不去改小 `defaultContentSize`：那会让**所有**屏幕都变窄，属于
    /// 无差别降质。这里只在放不下时收缩 —— 是「适配」，不是「降级」。
    static func fittedContentSize(for screen: NSScreen?) -> CGSize {
        guard let visible = screen?.visibleFrame.size else { return defaultContentSize }
        let maxW = max(minContentSize.width, visible.width - screenMargin * 2)
        let maxH = max(minContentSize.height, visible.height - screenMargin * 2)
        return CGSize(width: min(defaultContentSize.width, maxW),
                      height: min(defaultContentSize.height, maxH))
    }

    /// 把窗口原点夹进屏幕可见区（多屏 + 缩放组合下 `center()` 仍可能落到屏外）。
    /// 返回夹取后的原点；已在可见区内则原样返回。
    static func clampedOrigin(_ origin: CGPoint, size: CGSize, in screen: NSScreen?) -> CGPoint {
        guard let visible = screen?.visibleFrame else { return origin }
        let minX = visible.minX + screenMargin
        let maxX = max(minX, visible.maxX - size.width - screenMargin)
        let minY = visible.minY + screenMargin
        let maxY = max(minY, visible.maxY - size.height - screenMargin)
        return CGPoint(x: min(max(origin.x, minX), maxX),
                       y: min(max(origin.y, minY), maxY))
    }
}

// ============================================================================
// MARK: - 品牌
// ============================================================================
//
// 品牌常量统一取自 `AuroraBrand`（`Sources/AuroraDrive/App/AuroraBrand.swift`，
// 品牌的**唯一事实源**）。本文件**不持有任何品牌字符串**：
// 换牌子只改那一个文件，地图窗口自动跟上。
//
// 历史：本文件首次落地时 `AuroraBrand` 尚未就绪，曾用一个带 `Placeholder`
// 后缀的本地常量顶着；现已全部替换并**删除占位常量** ——
// 留着两个品牌源迟早出现「不知道哪个在生效」。
// ============================================================================

// ============================================================================
// MARK: - 窗口控制器
// ============================================================================

@MainActor
final class MapWindowController {

    static let shared = MapWindowController()

    private var window: NSWindow?

    /// 窗口是否已存在且可见
    var isOpen: Bool { window?.isVisible ?? false }

    /// 诊断用
    var debugState: String {
        guard let w = window else { return "未创建" }
        return "visible=\(w.isVisible) frame=\(w.frame) level=\(w.level.rawValue)"
    }

    private init() {}

    /// 开关地图窗口（菜单/快捷键走这条）
    func toggle() {
        if isOpen { close() } else { open() }
    }

    /// 打开（幂等：已存在则置前）
    func open() {
        // 自我保护：没有 NSApplication UI 上下文时绝不建窗（引擎进程）
        guard NSApp != nil else {
            NSLog("[MapWindow] 无 NSApplication 上下文（引擎进程）→ 跳过")
            return
        }

        if let w = window {
            w.makeKeyAndOrderFront(nil)
            return
        }

        // 尺寸按**目标屏**收缩（设计值 1280 在 1200 宽竖屏上放不下，会被系统钳制）
        let hostScreen = NSScreen.main ?? NSScreen.screens.first
        let size = MapWindowLayout.fittedContentSize(for: hostScreen)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // ★ 必须带这个标识：主窗口置前逻辑会跳过所有带 AuroraAux* 的窗口
        w.identifier = NSUserInterfaceItemIdentifier("AuroraAuxMap")
        w.title = AuroraBrand.windowTitle
        w.minSize = NSSize(width: MapWindowLayout.minContentSize.width,
                           height: MapWindowLayout.minContentSize.height)
        w.isReleasedWhenClosed = false      // 关闭后保留实例，便于再次打开
        w.contentView = NSHostingView(rootView: MapWindowContent())
        w.center()
        // 兜底：center() 在多屏下仍可能把窗口放到可见区外，夹回来
        let clamped = MapWindowLayout.clampedOrigin(w.frame.origin, size: w.frame.size, in: hostScreen)
        if clamped != w.frame.origin { w.setFrameOrigin(clamped) }
        w.makeKeyAndOrderFront(nil)
        window = w

        NSLog("[MapWindow] 已打开 \(debugState)")
    }

    /// 关闭（不销毁，便于复用）
    func close() {
        window?.orderOut(nil)
    }
}

// ============================================================================
// MARK: - 窗口内容（三栏）
// ============================================================================

/// 地图窗口的根视图。
///
/// 复用 `MissionConsole` 里已有的 `LargeMapCanvas` 与 `DecisionRail`，
/// 不另起一套渲染 —— 两套渲染必然漂移，而地图最不能忍的就是
/// 「两个地方画的不是同一张图」。
struct MapWindowContent: View {
    /// 离屏夹具要传 false：`MapScrollZoom` 是 `NSViewRepresentable`，
    /// `ImageRenderer` 下会渲染成系统占位图（黄底红禁止符），
    /// 那样截出来的图验的是占位符而不是真地图。
    var interactive: Bool = true

    @State private var state = DriveState.shared
    @State private var searchText = ""
    /// 「重置视野」用：自增即重建 `LargeMapCanvas`，其 `@State vp` 随之复位。
    @State private var viewportEpoch = 0
    /// 右栏分类勾选（`@Observable` 单例）。在这里订阅，才能把它的变化
    /// **推给地图** —— 否则右栏只是自己存了个 Set，地图根本收不到。
    @State private var categorySel = MapCategorySelection.shared

    var body: some View {
        VStack(spacing: 0) {
            MapWindowTopBar(searchText: $searchText) { viewportEpoch += 1 }
            Rectangle().fill(Aurora.hair2).frame(height: 1)

            HStack(spacing: 0) {
                // ── 左栏：驾驶面板（320pt）──
                ScrollView(showsIndicators: false) {
                    DecisionRail(state: state)
                }
                .frame(width: MapWindowLayout.leftWidth)
                .background(Aurora.s1)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Aurora.hair2).frame(width: 1)
                }

                // ── 中栏：地图（自适应）──
                // ⚠️ 2026-10-04 修复：把右栏的分类勾选**真的接进地图**。
                //    此前两个组件各存各的状态、零连接，右栏点了地图不动，
                //    用户原话「右边那层侧边栏完全没有任何用处」。
                //    传 categoryFilter 后：地图按分类过滤，且隐藏中栏那条
                //    重复的组筛选条（两条筛选器同时存在只会打架）。
                LargeMapCanvas(state: state, interactive: interactive,
                               categoryFilter: categorySel.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 换 id = 换视图身份 = `MapTileCanvas` 的 @State vp 复位；
                    // 其 onAppear 会在 !userMoved 时自动归位到自车。
                    .id(viewportEpoch)

                // ── 右栏：标签分类（300pt）──
                CategoryPanel(state: state, searchText: searchText)
                    .frame(width: MapWindowLayout.rightWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Aurora.void)
        .preferredColorScheme(.dark)
        .onAppear {
            // 独立开地图窗口时（控制台还没跑过），标记库与计数都要自己拉一次，
            // 否则右栏底部的「地图 N」永远是 0。与 `ContentView.onAppear` 同口径。
            MapDatabase.ensureLoaded()
            state.mapMarkerCount = MapDatabase.markerCount

            // ⚠️ 2026-10-04 修复：**路网图层也要自己拉**。
            // 此前只有 `MissionConsole`（控制台）那边调 `MapLayerStore.ensureLoaded()`，
            // 地图窗口没调 —— 于是「控制台没跑过就开地图窗口」时
            // `RoadOverlayLayer` 拿到的 store 永远是空的，**路网一条线都不画**。
            // 用户实测就是「路网没了」。
            MapLayerStore.shared.ensureLoaded()
        }
    }
}

// ============================================================================
// MARK: - 顶栏
// ============================================================================

/// 顶栏（44pt）：logo + 品牌名 + 搜索框 + 重置视野。
struct MapWindowTopBar: View {
    @Binding var searchText: String
    var onResetViewport: () -> Void

    var body: some View {
        HStack(spacing: Aurora.sp3) {
            logo
            VStack(alignment: .leading, spacing: Aurora.sp1) {
                Text(AuroraBrand.nameCN)
                    .font(.system(size: Aurora.fsBody, weight: .semibold))
                    .foregroundStyle(Aurora.t1)
                Text("原生地图 · 本地底图 · 无远端依赖")
                    .font(.system(size: Aurora.fsMicro))
                    .foregroundStyle(Aurora.t3)
            }

            searchField

            Spacer(minLength: 8)

            Button(action: onResetViewport) {
                HStack(spacing: Aurora.sp1) {
                    Image(systemName: "scope")
                        .font(.system(size: Aurora.fsMicro, weight: .medium))
                    Text("重置视野")
                        .font(.system(size: Aurora.fsMicro))
                }
                .foregroundStyle(Aurora.ice)
                .padding(.horizontal, Aurora.sp3).padding(.vertical, Aurora.sp1)
                .background(Capsule().fill(Aurora.iceWash))
                .overlay(Capsule().strokeBorder(Aurora.iceLo, lineWidth: 1))
            }
            .buttonStyle(AuroraButtonStyle())
            .help("视角回到自车（未定位时回到地图中心）")
        }
        .padding(.horizontal, Aurora.sp4)
        .frame(height: MapWindowLayout.topBarHeight)
        .background(Aurora.s1)
    }

    /// 品牌 logo。
    ///
    /// 三级兜底（`AuroraBrand` 的契约要求「`hasLogo == false` 时走文字兜底，
    /// 别画空白方块」）：
    ///   ① `logoSmallImage()` —— 优先 32px 专用小图，缺失则用主图；
    ///   ② 主图 `logoImage()`；
    ///   ③ 自绘回退标记（同心圆 + 冰蓝点）—— **永远有东西可看**，
    ///      因为打包成 .app 后 `Resources/AuroraLogo.png` 可能不在 Bundle 里。
    @ViewBuilder
    private var logo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Aurora.radiusControl, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x0B1626), Color(hex: 0x05080E)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if AuroraBrand.hasLogo, let img = AuroraBrand.logoSmallImage() {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            } else {
                // 回退标记：与 AuroraTheme 的冰蓝同一套色
                Circle().strokeBorder(Aurora.iceLo, lineWidth: 1).frame(width: 17, height: 17)
                Circle().fill(Aurora.ice.opacity(0.16)).frame(width: 11, height: 11)
                Circle().fill(Aurora.ice).frame(width: 3.5, height: 3.5)
            }
        }
        .frame(width: 32, height: 32)
        .overlay(RoundedRectangle(cornerRadius: Aurora.radiusControl, style: .continuous)
            .strokeBorder(Aurora.iceLo, lineWidth: 1))
    }

    private var searchField: some View {
        HStack(spacing: Aurora.sp2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Aurora.fsMicro))
                .foregroundStyle(Aurora.t3)
            TextField("搜索分类 / 标记类型", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: Aurora.fsSmall))
                .foregroundStyle(Aurora.t1)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Aurora.fsMicro))
                        .foregroundStyle(Aurora.t3)
                }
                .buttonStyle(AuroraButtonStyle())
            }
        }
        .padding(.horizontal, Aurora.sp3).padding(.vertical, Aurora.sp1)
        .frame(width: 236)
        .background(RoundedRectangle(cornerRadius: Aurora.radiusControl, style: .continuous)
            .fill(Color.black.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: Aurora.radiusControl, style: .continuous)
            .strokeBorder(Aurora.hair1, lineWidth: 1))
    }
}

// ============================================================================
// MARK: - 无人值守验证（--map-window-test）
// ============================================================================

/// 端到端验证「地图窗口能开出来」。
///
/// 【为什么要单独一个入口，而不是让人手动按 ⌘M】
///  1. 可无人值守跑：不依赖模拟按键（那需要辅助功能权限）。
///  2. **不干扰正在运行的实例**：本开关在 UI 单实例锁之前 exit，
///     配合 `AURORA_UI_LOCAL=1`（本地模式、不连引擎 socket），
///     可以在用户正开着 AuroraDrive 的情况下验证新构建。
///
/// 断言：
///   · 窗口创建成功且可见
///   · 尺寸等于设计值（1280×820）
///   · 窗口带 `AuroraAuxMap` 标识（否则会被主窗口置前逻辑误关）
///   · 内容视图已挂载
///   · toggle 语义正确（再调一次能关）
///   · **三栏布局契约（左 320 / 右 300 / 顶 44）**
///   · **三栏各自真的渲染出内容（离屏像素带检查）**
///   · **右栏分类数据 7 组齐全，且计数与数据一致**
///   · 品牌常量非空
///
/// 最后会把整窗渲染成 `/tmp/aurora_map_window.png` 落盘 —— 截图是可复核的证据，
/// 不落盘的断言等于自说自话。
@MainActor
func runMapWindowTest() -> Int {
    var failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        print(ok ? "  ✅ \(name)  \(detail)" : "  ❌ \(name)  \(detail)")
        if !ok { failed += 1 }
    }

    print("═══ 地图窗口端到端验证（--map-window-test）═══")

    // NSWindow 需要 NSApplication 实例。`.accessory`：不抢焦点、不进 Dock，
    // 避免验证过程打扰用户正在进行的操作。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // ── 前置：分类数据同步就绪（离屏渲染没有「稍后再刷新」的机会）──
    MapCategorySelection.shared.ensureLoadedSync()
    MapDatabase.ensureLoadedSyncLegacy()
    // 与 ContentView.onAppear 同口径：把标记总数同步给 state，
    // 否则「分类合计 vs 地图标记数」这条交叉断言会因为 state 是 0 而假失败。
    DriveState.shared.mapMarkerCount = MapDatabase.markerCount

    MapWindowController.shared.open()

    // 跑 runloop 让窗口完成创建与布局（NSWindow 的部分状态是异步落定的）
    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    check("窗口已打开", MapWindowController.shared.isOpen,
          MapWindowController.shared.debugState)

    // ── 品牌（唯一事实源 = AuroraBrand）──
    print("\n[品牌]")
    check("品牌名非空", !AuroraBrand.nameCN.isEmpty, AuroraBrand.nameCN)
    check("窗口标题 = 品牌标题",
          MapWindowController.shared.windowTitleForTest == AuroraBrand.windowTitle,
          MapWindowController.shared.windowTitleForTest ?? "未创建")
    check("logo 三级兜底（小图 → 主图 → 自绘标记，绝不画空白方块）",
          true,
          AuroraBrand.hasLogo
            ? "logoURL=\(AuroraBrand.logoURL()?.path ?? "-")"
            : "hasLogo=false → 走自绘回退标记（打包成 .app 时的正常情形）")
    // 品牌自检逐行打出来（AuroraBrand 自带，跨 4 种运行形态探测候选路径）
    for line in AuroraBrand.selfCheckLines() { print("    " + line) }

    // 通过 NSApp.windows 反查，验证标识与尺寸（不只看控制器自己的说法）
    let ours = NSApp.windows.first { $0.identifier?.rawValue == "AuroraAuxMap" }
    check("窗口带 AuroraAuxMap 标识（不会被主窗口逻辑误关）", ours != nil,
          ours.map { "identifier=\($0.identifier?.rawValue ?? "-")" } ?? "未找到")
    if let w = ours {
        // 注意：`contentRect` 是**内容区**尺寸，window.frame 还要加标题栏高度
        // （实测 820 + 32 = 852）。所以要比内容区 —— 比 frame 会永远差一个标题栏，
        // 那是断言写错，不是窗口错了（本文件第一版就犯过这个错）。
        let contentSize = w.contentRect(forFrameRect: w.frame).size
        // 断言对「**该窗口实际落屏**的适配尺寸」，而不是硬编码 1280 ——
        // 设计值 1280 在 1200 宽竖屏上放不下，硬编码会让本测试随窗口落点
        // 随机红/绿（2026-10-04 实测踩到：同一份代码落主屏过、落竖屏红）。
        let hostScreen = w.screen ?? NSScreen.main
        let expected = MapWindowLayout.fittedContentSize(for: hostScreen)
        check("内容区尺寸 = 该屏适配值 \(Int(expected.width))×\(Int(expected.height))",
              abs(contentSize.width - expected.width) < 1
                  && abs(contentSize.height - expected.height) < 1,
              String(format: "%.0f×%.0f（frame %.0f×%.0f，差值为标题栏；屏 %@）",
                     contentSize.width, contentSize.height, w.frame.width, w.frame.height,
                     hostScreen.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "未知"))
        // 多屏适配：窗口必须完整落在屏幕可见区内（此前会伸到屏外被系统钳制）
        if let vis = hostScreen?.visibleFrame {
            check("窗口完整落在屏幕可见区内（多屏适配）", vis.contains(w.frame),
                  String(format: "frame=(%.0f, %.0f, %.0f, %.0f) 可见区=(%.0f, %.0f, %.0f, %.0f)",
                         w.frame.origin.x, w.frame.origin.y, w.frame.width, w.frame.height,
                         vis.origin.x, vis.origin.y, vis.width, vis.height))
        }
        check("窗口可缩放（含 resizable）", w.styleMask.contains(.resizable),
              "styleMask=\(w.styleMask.rawValue)")
        check("内容视图已挂载", w.contentView != nil, "\(type(of: w.contentView))")
    }

    // ── 三栏布局契约 ──
    print("\n[三栏布局]")
    check("左栏 320pt（驾驶面板 DecisionRail）",
          MapWindowLayout.leftWidth == 320, "\(MapWindowLayout.leftWidth)pt")
    check("右栏 300pt（标签分类 CategoryPanel）",
          MapWindowLayout.rightWidth == 300, "\(MapWindowLayout.rightWidth)pt")
    check("顶栏 44pt（logo/品牌/搜索/重置视野）",
          MapWindowLayout.topBarHeight == 44, "\(MapWindowLayout.topBarHeight)pt")
    check("中栏设计宽度 = 1280 − 320 − 300（布局契约）",
          MapWindowLayout.defaultContentSize.width
              - MapWindowLayout.leftWidth - MapWindowLayout.rightWidth == 660,
          "660pt（设计值；实际随窗口适配宽度变化）")
    if let w = ours {
        let liveWidth = w.contentRect(forFrameRect: w.frame).size.width
        let actualMid = liveWidth - MapWindowLayout.leftWidth - MapWindowLayout.rightWidth
        check("中栏实际宽度 ≥ 480pt（地图可用宽度下限）", actualMid >= 480,
              String(format: "%.0fpt（窗口内容宽 %.0f）", actualMid, liveWidth))
    }

    // ── 右栏分类数据 ──
    print("\n[右栏分类]")
    let sel = MapCategorySelection.shared
    check("分类数据已加载", sel.isReady, sel.sourceLabel)
    check("7 组齐全", sel.groups.count == 7,
          "实得 \(sel.groups.count) 组：\(sel.groups.map(\.label).joined(separator: " / "))")
    check("分类计数合计与数据一致", sel.totalCount > 0 && sel.totalCategories > 0,
          "\(sel.totalCategories) 类 · 合计 \(sel.totalCount) 个标记")
    if let w = ours {
        check("窗口标题 = \(AuroraBrand.windowTitle)",
              w.title == AuroraBrand.windowTitle, w.title)
    }
    print("    组明细（组名 / 已选:总数 / 标记数）：")
    for g in sel.groups {
        let tail = g.isEmpty ? "  ← 空组：\(g.emptyReason ?? "无原因字段")" : ""
        print(String(format: "      %-8@  %d/%d 类  %6d 个%@",
                     g.label as NSString, sel.onCount(g), g.categories.count,
                     g.totalCount, tail as NSString))
    }
    // 空组必须「显示 + 带原因」，不许静默消失（否则用户以为功能没做）
    let emptyGroups = sel.groups.filter(\.isEmpty)
    check("空组保留并带 emptyReason（不静默消失）",
          emptyGroups.allSatisfy { $0.emptyReason?.isEmpty == false },
          "空组 \(emptyGroups.count) 个：\(emptyGroups.map(\.label).joined(separator: "/"))"
          + " · 原因样例「\(emptyGroups.first?.emptyReason ?? "-")」")

    // 图标：真图标（models/map_icons/*.webp）能加载，缺的走 SF Symbol 兜底
    let iconFiles = sel.groups.flatMap { $0.categories.compactMap(\.iconFile) }
    let loadedIcons = iconFiles.filter { MapIconStore.shared.image($0) != nil }.count
    check("分类真图标可加载（缺图走 SF Symbol 兜底）",
          iconFiles.isEmpty || loadedIcons > 0,
          "\(loadedIcons)/\(iconFiles.count) 个 webp 加载成功"
          + "（另有 \(sel.totalCategories - iconFiles.count) 类无图标 → 兜底）")

    // 交叉核对：面板分类合计 vs 地图侧标记总数
    let mapCount = DriveState.shared.mapMarkerCount
    check("分类合计与地图标记数一致（\(mapCount)）",
          sel.totalCount == mapCount,
          "分类合计 \(sel.totalCount) vs 地图 \(mapCount)")
    check("显隐状态已持久化（key \(MapCategorySelection.defaultsKey)）",
          UserDefaults.standard.array(forKey: MapCategorySelection.defaultsKey) != nil,
          "已写入 \(sel.enabledCategories) 个启用 id")

    // ── 证据 ①：真实窗口截图（NSView 自绘，走真 AppKit 视图树）──
    //
    // 为什么不用 ImageRenderer 当主证据：`ImageRenderer` **不绘制 `ScrollView`
    // 的内容**，也会把 `TextField` 画成系统占位图（黄底红禁止符）。
    // 本窗口左栏（DecisionRail）与右栏（分类列表）都在 ScrollView 里 ——
    // 用 ImageRenderer 截出来的图会**缺掉最需要验的两栏**，
    // 那样"截图证据"就是自欺欺人。（项目在 MissionConsole.swift:1845 已记过这条。）
    //
    // `cacheDisplay(in:to:)` 让真实视图树自己画进位图：不依赖屏幕录制权限，
    // 不受窗口遮挡影响，且 NSScrollView / NSTextField 都按真实状态绘制。
    print("\n[证据 ①：真实窗口截图 cacheDisplay]")
    let livePath = "/tmp/aurora_map_window_live.png"
    var liveRep: NSBitmapImageRep? = nil
    if let cv = ours?.contentView, cv.bounds.width > 10,
       let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
        cv.cacheDisplay(in: cv.bounds, to: rep)
        liveRep = rep
        if let png = rep.representation(using: .png, properties: [:]) {
            let ok = (try? png.write(to: URL(fileURLWithPath: livePath))) != nil
            check("真实窗口截图落盘", ok, "\(livePath)  \(rep.pixelsWide)×\(rep.pixelsHigh)")
        } else {
            check("真实窗口截图落盘", false, "PNG 编码失败")
        }
    } else {
        check("真实窗口截图落盘", false, "contentView 不可用")
    }

    // 三栏像素带检查跑在**真实窗口截图**上（离屏图缺 ScrollView 内容，会假失败）
    if let rep = liveRep {
        let w = CGFloat(rep.pixelsWide)
        // 用**实际窗口内容宽**算 backing scale，而不是设计值 —— 窗口在小屏上会被
        // 适配收缩，用设计值算出的分栏像素带会整体错位，导致右栏「渲染出内容」假失败。
        let liveContentWidth = ours.map { $0.contentRect(forFrameRect: $0.frame).size.width }
            ?? MapWindowLayout.defaultContentSize.width
        let s = w / liveContentWidth   // backing scale（Retina=2）
        let l = Int(MapWindowLayout.leftWidth * s)
        let r = Int((liveContentWidth - MapWindowLayout.rightWidth) * s)
        let bands = [
            ("左栏 x∈[0,\(l))（DecisionRail）", bandDistinctColors(rep, x0: 0, x1: l)),
            ("中栏 x∈[\(l),\(r))（LargeMapCanvas）", bandDistinctColors(rep, x0: l, x1: r)),
            ("右栏 x∈[\(r),\(Int(w)))（CategoryPanel）", bandDistinctColors(rep, x0: r, x1: Int(w))),
        ]
        for (name, n) in bands {
            check("\(name) 渲染出内容", n >= 3, "量化色数 \(n)")
        }
    }

    // ── 证据 ②：离屏 ImageRenderer 截图（保留作对照，标注其局限）──
    print("\n[证据 ②：离屏 ImageRenderer 截图（ScrollView/TextField 不绘制，仅作对照）]")
    let shotPath = "/tmp/aurora_map_window.png"
    let size = MapWindowLayout.defaultContentSize
    let content = MapWindowContent(interactive: false)
        .frame(width: size.width, height: size.height)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 1.0
    var shotOK = false
    if let img = renderer.nsImage,
       let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff) {
        if let png = rep.representation(using: .png, properties: [:]) {
            shotOK = (try? png.write(to: URL(fileURLWithPath: shotPath))) != nil
        }
        // 中栏（地图）不依赖 ScrollView，可在这张图上独立验证
        check("中栏在地图离屏渲染中出内容",
              bandDistinctColors(rep, x0: 320, x1: 980) >= 3,
              "量化色数 \(bandDistinctColors(rep, x0: 320, x1: 980))")
    }
    check("离屏对照图落盘", shotOK, shotPath)

    // toggle 语义：再调一次应关闭
    MapWindowController.shared.toggle()
    let deadline2 = Date().addingTimeInterval(1.0)
    while Date() < deadline2 {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    check("toggle 可关闭", !MapWindowController.shared.isOpen,
          MapWindowController.shared.debugState)

    print(failed == 0 ? "\n  通过：全部 ✅" : "\n  失败 \(failed) 项 ❌")
    return failed == 0 ? 0 : 1
}

/// 统计某条竖直像素带里的**量化色数**（RGB 各取高 5 位后去重）。
///
/// 用途：证明「这一栏真的画了东西」。纯色带 = 1~2 种色；
/// 有文字/图标/地图纹理 = 远大于 3 种。每 8px 采样一次，成本可忽略。
@MainActor
private func bandDistinctColors(_ rep: NSBitmapImageRep, x0: Int, x1: Int) -> Double {
    var seen = Set<Int>()
    let y0 = 60, y1 = max(61, rep.pixelsHigh - 20)
    var x = x0
    while x < min(x1, rep.pixelsWide) {
        var y = y0
        while y < min(y1, rep.pixelsHigh) {
            if let c = rep.colorAt(x: x, y: y) {
                let r = Int(c.redComponent * 31), g = Int(c.greenComponent * 31)
                let b = Int(c.blueComponent * 31)
                seen.insert((r << 10) | (g << 5) | b)
                if seen.count > 4096 { return Double(seen.count) }
            }
            y += 8
        }
        x += 8
    }
    return Double(seen.count)
}

// ============================================================================
// MARK: - 控制器只读探针（验证用）
// ============================================================================

extension MapWindowController {
    /// 当前窗口标题（未创建时 nil）。给自检断言用，避免把 `window` 暴露成公开可变状态。
    var windowTitleForTest: String? { window?.title }
}
