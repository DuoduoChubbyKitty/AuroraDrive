// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  GameMapView.swift — 异环游戏交互式地图 (v3)
//  ──────────────────────────────────────────────────────────────────────────
//  功能：
//    · 顶部三模式分段控件：正常地图 / 按种类筛选 / 选择地图
//    · 左侧侧边栏：分类选择器 + 索引搜索（按拼音/字母快速定位）
//    · 正常模式：仅显示传送点+地名（轻量底图）
//    · 筛选模式：勾选分类显示对应标记（材料/BOSS/怪物等）
//    · 选图模式：按区域快速跳转 + 缩放定位
//    · 标记点点击：弹出详情卡片（名称/类型/坐标/区域）
//  数据：models/nte-game.jpg (4K底图) + models/FINAL_complete_map_database.json
//  设计：Tesla FSD 驾驶舱风格 · 纯黑底 + 青色(#00E5FF)发光 · 玻璃拟态
//  字体：SF Rounded（标题/正文）+ SF Mono（坐标/数字）
// ============================================================================

import SwiftUI
import AppKit
import Foundation

// MARK: - 数据模型

/// 完整地图数据库（从 FINAL_complete_map_database.json 加载）
struct MapDatabase: Codable {
    let summary: DatabaseSummary?
    let markers_all: [MapMarker]?
    let waypoints: [MapMarker]?
    let phone_booths: [MapMarker]?
    let towers: [MapMarker]?
    let services: [MapMarker]?
    let shops: [MapMarker]?
    let bosses: [MapMarker]?
    let monsters: [MapMarker]?
    let regions: [MapMarker]?
    let materials: [MapMarker]?
    let quests_activities: [MapMarker]?
    let marker_types: [String: MarkerTypeInfo]?
}

struct DatabaseSummary: Codable {
    let total_markers: Int?
    let bounds_percent: BoundsPercent?
    let by_category: [String: Int]?
    let marker_types_cn: [String: String]?
    let regions_cn: [String: RegionInfo]?
}

struct BoundsPercent: Codable {
    let x_min: Double?
    let x_max: Double?
    let y_min: Double?
    let y_max: Double?
}

struct RegionInfo: Codable {
    let zh: String?
    let en: String?
    let color: String?
}

struct MarkerTypeInfo: Codable {
    let color: String?
    let label: String?
    let labelEn: String?
}

/// 单个地图标记（统一结构，所有字段可选以容错）
struct MapMarker: Codable, Identifiable, Hashable {
    var id: String { "\(type ?? "?")_\(Int(x ?? 0))_\(Int(y ?? 0))_\(name ?? "")" }
    let name: String?
    let nameEn: String?
    let type: String?
    let x: Double?
    let y: Double?
    let subtype: String?
    let region: String?
    let icon: String?
    let link: String?

    // 不解码 JSON 中的 id 字段（值类型不统一：有的字符串有的数字）
    // Identifiable 的 id 用计算属性生成，避免解码冲突
    enum CodingKeys: String, CodingKey {
        case name, nameEn, type, x, y, subtype, region, icon, link
    }

    /// 清理 HTML 标签后的显示名
    var displayName: String {
        let raw = name ?? nameEn ?? "?"
        return raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                   .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 用于地图标签的简短中文名（避免重复名拥挤）
    /// 传送点：按 subtype 显示「快旅」/「计程车」
    /// 塔：显示「维特海默塔」
    /// 区域：显示中文名
    /// 其他：显示 displayName
    var labelName: String {
        let t = type ?? ""
        switch t {
        case "waypoint":
            // subtype: fast-travel / taxi
            let sub = subtype ?? ""
            if sub.contains("taxi") { return "计程车" }
            return "传送点"
        case "tower":
            return "维特海默塔"
        case "phone-booth":
            return "电话亭"
        case "oracle-stone":
            return "谕石"
        case "chest":
            return "宝箱"
        case "boss":
            // BOSS 用 displayName 保留具体名字
            return displayName
        default:
            return displayName
        }
    }

    /// 坐标安全取值
    var safeX: Double { x ?? 50.0 }
    var safeY: Double { y ?? 50.0 }

    /// 拼音首字母（用于索引）—— 简化版：取 displayName 首字符
    /// 完整拼音转换需引入 CFStringTokenizer，此处用首字符大写分类
    var indexKey: String {
        let first = displayName.first.map(String.init) ?? "#"
        if first.range(of: "[A-Za-z]", options: .regularExpression) != nil {
            return first.uppercased()
        } else if first.range(of: "[0-9]", options: .regularExpression) != nil {
            return "#"
        } else {
            return "中"
        }
    }
}

// MARK: - 地图模式

/// 三种地图模式（顶部三选项）
enum MapMode: String, CaseIterable, Identifiable {
    case normal    = "正常地图"
    case filter    = "按种类筛选"
    case selectMap = "选择地图"

    var id: String { rawValue }

    /// SF Symbol 图标
    var icon: String {
        switch self {
        case .normal:    return "map"
        case .filter:    return "line.3.horizontal.decrease.circle"
        case .selectMap: return "square.grid.2x2"
        }
    }

    /// 模式副标题
    var subtitle: String {
        switch self {
        case .normal:    return "传送点 · 地名"
        case .filter:    return "材料 · BOSS · 怪物"
        case .selectMap: return "区域 · 快速定位"
        }
    }
}

// MARK: - 分类配置

/// 标记分类配置（侧边栏筛选用）
struct MarkerCategory: Identifiable, Hashable {
    let id: String          // 类型 key，如 "waypoint"
    let label: String       // 中文标签
    let color: Color        // 显示颜色
    let icon: String        // SF Symbol
    var isEnabled: Bool     // 是否启用
    var count: Int          // 标记数量

    /// 从 nteguide 颜色字符串解析 SwiftUI Color
    static func parseColor(_ hex: String?) -> Color {
        guard let hex = hex else { return Theme.cyan }
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        guard let v = UInt32(cleaned, radix: 16) else { return Theme.cyan }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - 主视图

struct GameMapView: View {
    // ── 数据路径 ──
    // ⚠️ 原 yihuan_map_z5.png 为游戏地图，道路拼接错乱，已弃用
    // 主底图改用 IMG_1366 截图，经 PIL Lanczos 4x 超分（8636×8592，文字平滑抗锯齿、不被改写）
    // ⚠️ 旧底图 enhanced_1366.png 已废弃（一张无内容的超分截图，缓兵之计），由用户手动删除。
    // 新底图改用 MaaNTE 官方大世界地图 bigworldmapSecond.png（11264×11264 高清路网，与现地图同版）。
    private let mapImagePath = "/Users/dupi/Desktop/自动驾驶系统/models/bigworldmapSecond.png"
    private let altMapImagePath = "/Users/dupi/Desktop/自动驾驶系统/models/yihuan_map_z4.png"
    private let dataPath = "/Users/dupi/Desktop/自动驾驶系统/models/FINAL_complete_map_database.json"

    @Environment(\.dismiss) private var dismiss

    // 缩放/拖拽
    // 初始缩放 0.15 让 8192px 地图缩到 1229px 适配画面
    @State private var scale: CGFloat = 0.11
    @State private var lastScale: CGFloat = 0.11
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    // ── 数据 ──
    @State private var db: MapDatabase?
    @State private var mapImage: NSImage?
    @State private var mapSize: CGFloat = 3840
    @State private var mapAspect: CGFloat = 16.0 / 9.0
    @State private var isLoading: Bool = true    // 加载状态（启动动画用）

    // ── 模式 ──
    @State private var mode: MapMode = .normal

    // ── 分类筛选 ──
    @State private var categories: [MarkerCategory] = []

    // ── 选中/搜索 ──
    @State private var selectedMarker: MapMarker?
    @State private var searchText: String = ""
    @State private var selectedRegion: String?

    // ── 关闭动画 ──
    @State private var isClosing: Bool = false

    // ── 标记分层缓存（P 性能）──
    // 缓存「按类型优先级排好序的候选池」，键 = 启用类型集合 + 搜索词。
    // 平移/缩放时 body 每帧重算 filteredMarkers，但 filter+sort 5677 个标记是
    // O(n log n) 大头；缓存后每帧只做 O(cap) 的均匀抽样，拖动不再卡。
    @State private var sortedPoolCache: [MapMarker] = []
    @State private var sortedPoolKey: String = ""

    // ── 侧边栏 tab（筛选模式下：分类 / 索引）──
    @State private var sidebarTab: SidebarTab = .categories

    // ── 图层浮层开关（常驻，随时拉下，独立于模式）──
    @State private var layersOpen: Bool = false

    /// 侧边栏子标签
    enum SidebarTab: String, CaseIterable, Identifiable {
        case categories = "分类"
        case index      = "索引"
        var id: String { rawValue }
    }

    // 正常模式下始终显示的类型（轻量底图）
    private let normalModeTypes: Set<String> = ["waypoint", "phone-booth", "tower", "region"]

    /// 所有支持的分类定义（id -> 标签/图标），材料已细分
    /// 用于侧边栏筛选 + 正常模式分层渲染
    private static let categoryDefs: [(id: String, label: String, icon: String)] = [
        ("waypoint",     "传送点",       "location.fill"),
        ("region",       "区域地名",      "mappin.circle"),
        ("phone-booth",  "电话亭",       "phone.fill"),
        ("tower",        "维特海默塔",    "building.columns"),
        ("boss",         "异象BOSS",     "skull.fill"),
        ("quest",        "任务",         "checkmark.seal.fill"),
        ("activity",     "活动",         "calendar.circle.fill"),
        ("viewpoint",    "景点",         "camera.fill"),
        ("service",      "城市服务",      "briefcase.fill"),
        ("shop",         "商店",         "bag.fill"),
        // ── 材料细分 ──
        ("oracle-stone", "谕石(玉石)",   "gem.fill"),         // 258个，紫色
        ("chest",        "宝箱",         "shippingbox.fill"), // 109个，橙色
        ("collectible",  "收集品",       "sparkles"),         // 641个，绿色(避役包裹等)
        ("mystery-box",  "神秘箱",       "questionmark.diamond.fill"), // 966个，紫色
        ("gift-21",      "「21」的赠礼",  "gift.fill"),        // 112个，粉色
        ("currency",     "货币战利品",    "dollarsign.circle.fill"),    // 964个，黄色
        ("arc-plate",    "弧盘",         "circle.hexagongrid.fill"),   // 27个，紫色
        ("monster",      "怪物",         "ant.fill"),         // 712个，红色
    ]

    var body: some View {
        ZStack {
            // ── 1. 深空背景（最底层）──
            ZStack {
                Color.black.ignoresSafeArea()
                RadialGradient(
                    gradient: Gradient(colors: [Theme.cyan.opacity(0.06), .clear]),
                    center: .center,
                    startRadius: 0,
                    endRadius: 600
                )
                .ignoresSafeArea()
            }
            .allowsHitTesting(false)

            // ── 2. 地图画布（全屏底层）──
            mapCanvas

            // ── 3. 顶部工具条（标题+搜索+缩放）──
            VStack(spacing: 0) {
                topBar
                Spacer()
                if mode != .normal { bottomStatusBar }
            }
            .zIndex(10)

            // ── 4. 左侧侧边栏 ──
            HStack(spacing: 0) {
                if mode != .normal {
                    sidebar
                        .frame(width: 300)
                        .background(sidebarBackground)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer()
            }
            .zIndex(20)
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: mode)

            // ── 4.5 图层浮层（右侧常驻，弹簧拉下，随时开关，不依赖模式）──
            HStack(spacing: 0) {
                Spacer()
                if layersOpen {
                    layerPanel
                        .frame(width: 300)
                        .background(sidebarBackground)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .zIndex(25)
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: layersOpen)

            // ── 5. 三模式分段控件（顶部正中央，独立浮层）──
            // 放在 topBar 之上，确保可见可点
            VStack {
                HStack {
                    Spacer()
                    modeSegmentedControl
                        .shadow(color: Theme.cyan.opacity(0.3), radius: 6)
                    Spacer()
                }
                .padding(.top, 6)
                Spacer()
            }
            .zIndex(30)
            .allowsHitTesting(true)

            // ── 6. 关闭按钮（右下角浮动，独立浮层）──
            // 注意：不能用 allowsHitTesting(false) 包裹，否则按钮也点不到
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    closeButton
                        .padding(.trailing, 24)
                        .padding(.bottom, 24)
                }
            }
            .zIndex(40)

            // ── 7. 标记详情浮窗（选中时）──
            if let m = selectedMarker {
                markerDetailCard(m)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .zIndex(50)
            }

            // ── 8. 加载动画覆盖层（启动时短暂显示）──
            if isLoading {
                ZStack {
                    Color.black.opacity(0.85).ignoresSafeArea()
                    VStack(spacing: 18) {
                        // 呼吸圆环 + 旋转弧
                        ZStack {
                            Circle()
                                .stroke(Theme.cyan.opacity(0.15), lineWidth: 3)
                                .frame(width: 56, height: 56)
                            Circle()
                                .trim(from: 0, to: 0.7)
                                .stroke(
                                    AngularGradient(
                                        gradient: Gradient(colors: [Theme.cyan, Theme.cyan.opacity(0.3), .clear]),
                                        center: .center
                                    ),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                                )
                                .frame(width: 56, height: 56)
                                .rotationEffect(.degrees(-90))
                                .rotationEffect(.degrees(360))
                                .animation(
                                    .linear(duration: 0.9).repeatForever(autoreverses: false),
                                    value: isLoading
                                )
                        }
                        Text("正在加载地图…")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.cyan)
                            .shadow(color: Theme.cyan.opacity(0.6), radius: 4)
                            .tracking(2)
                    }
                }
                .transition(.opacity)
                .zIndex(1000)
            }
        }
        .onAppear { loadData() }
        .onDisappear {
            // P1 修复：关闭地图 sheet 时释放 8636×8592 巨图（解码后 ≈280MB 常驻），
            // 避免反复开合地图后内存累积。
            mapImage = nil
            db = nil
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selectedMarker)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: mode)
    }

    /// 关闭按钮（右下角浮动，带按下动画 + 关闭过渡）
    private var closeButton: some View {
        Button {
            // 关闭动画：先缩小淡出，再 dismiss
            withAnimation(.easeIn(duration: 0.18)) {
                isClosing = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                dismiss()
            }
        } label: {
            ZStack {
                // 外圈呼吸光晕
                Circle()
                    .fill(Color.red.opacity(0.20))
                    .frame(width: 52, height: 52)
                    .shadow(color: .red.opacity(0.7), radius: 10)
                // 主体红色渐变圆
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(red: 1.0, green: 0.40, blue: 0.32),
                                     Color(red: 0.78, green: 0.14, blue: 0.14)],
                            center: .center, startRadius: 0, endRadius: 22
                        )
                    )
                    .frame(width: 40, height: 40)
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.55), lineWidth: 1.4)
                            .frame(width: 40, height: 40)
                    )
                // xmark
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 1, y: 0.5)
            }
            .scaleEffect(isClosing ? 0.85 : 1.0)
            .opacity(isClosing ? 0.6 : 1.0)
        }
        .buttonStyle(.plain)
        .help("关闭地图")
    }

    /// 侧边栏背景：玻璃拟态 + 右侧青色细描边
    private var sidebarBackground: some View {
        ZStack {
            // 主体毛玻璃
            RoundedRectangle(cornerRadius: 0)
                .fill(.ultraThinMaterial.opacity(0.92))
            // 顶部细微高光
            LinearGradient(
                colors: [Theme.cyan.opacity(0.08), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 120)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            // 右侧描边发光
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Theme.cyan.opacity(0.4), Theme.cyan.opacity(0.08)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .shadow(color: Theme.cyan.opacity(0.3), radius: 4)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 地图画布

    private var mapCanvas: some View {
        Group {
            if let image = mapImage {
                GeometryReader { geo in
                    ZStack {
                        // 底图
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: mapSize * scale, height: mapSize * scale / mapAspect)
                            .clipped()
                            .overlay(
                                // 地图边缘渐隐遮罩，营造无限延伸感
                                LinearGradient(
                                    colors: [.black.opacity(0.4), .clear, .clear, .black.opacity(0.4)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                                .allowsHitTesting(false)
                            )

                        // 标记层
                        markerLayer
                    }
                    .offset(offset)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .gesture(dragGesture)
                    .gesture(magnifyGesture)
                    .onTapGesture { location in
                        // 点击空白处取消选中
                        if selectedMarker != nil {
                            selectedMarker = nil
                        }
                    }
                }
            } else {
                VStack(spacing: 14) {
                    // 自定义加载动画：呼吸圆环
                    ZStack {
                        Circle()
                            .stroke(Theme.cyan.opacity(0.2), lineWidth: 2)
                            .frame(width: 44, height: 44)
                        Circle()
                            .trim(from: 0, to: 0.7)
                            .stroke(Theme.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 44, height: 44)
                            .rotationEffect(.degrees(-90))
                            .rotationEffect(.degrees(360))
                            .animation(
                                .linear(duration: 1.0).repeatForever(autoreverses: false),
                                value: mapImage != nil
                            )
                    }
                    Text("加载地图数据中…")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .tracking(1)
                }
            }
        }
    }

    // 拖拽手势
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { g in
                offset = CGSize(
                    width: lastOffset.width + g.translation.width,
                    height: lastOffset.height + g.translation.height
                )
            }
            .onEnded { _ in lastOffset = offset }
    }

    // 缩放手势
    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { g in
                let delta = g / lastScale
                scale = min(max(lastScale * delta, 0.08), 3.0)
            }
            .onEnded { _ in lastScale = scale }
    }

    // MARK: - 标记层

    @ViewBuilder
    private var markerLayer: some View {
        if let db = db {
            let renderW = mapSize * scale
            let renderH = renderW / mapAspect
            let activeMarkers = filteredMarkers(db: db)

            ZStack {
                ForEach(activeMarkers) { m in
                    markerView(m, renderW: renderW, renderH: renderH)
                }
            }
            .frame(width: renderW, height: renderH)
        }
    }

    /// 根据图层开关状态返回要渲染的标记（图层浮层 / 筛选侧栏共享同一份 categories 状态）
    /// ⚠️ 标记坐标目前与底图可能未配准（旧数据），待本机重抓 nteguide 最新数据后校准。
    ///
    /// 分层渲染（P 性能）：全库 5677 个标记，若全部作为 SwiftUI 视图塞进 ZStack，
    /// 平移/缩放时每帧重建 5677 个 view 直接卡死。这里按缩放层级裁剪数量：
    ///   正常模式：只渲染核心导航层（waypoint/tower/region/phone-booth ≈ 130 个）—— 恒定量，不裁。
    ///   筛选模式：按 zoom 分层 200 / 500 / 1500 上限（与项目规范「200/500/1500 标记按缩放层级」一致）。
    /// 裁剪采用「类型优先级 + 均匀抽样」：核心类型（传送点/塔/地名/BOSS）始终保留，
    /// 超出上限的收集类（材料/宝箱/谕石…）按步长均匀抽取，保证空间分布不聚簇。
    private func filteredMarkers(db: MapDatabase) -> [MapMarker] {
        let enabledTypes = Set(categories.filter { $0.isEnabled }.map { $0.id })
        guard !enabledTypes.isEmpty else { return [] }

        // ── 分层上限：正常模式不裁（恒 ~130 核心标记）；筛选模式按缩放裁剪。──
        let cap: Int
        if mode == .normal {
            cap = Int.max
        } else if scale < 0.25 {
            cap = 200
        } else if scale < 0.6 {
            cap = 500
        } else {
            cap = 1500
        }

        // ── 排序候选池缓存：filter+sort 只依赖 categories+searchText（不依赖 scale/offset）──
        // 键变化才重建；平移/缩放 body 重算时直接复用，每帧只做 O(cap) 抽样。
        let key = enabledTypes.sorted().joined(separator: ",") + "|" + searchText
        if key != sortedPoolKey {
            let all = db.markers_all ?? []
            var result = all.filter { enabledTypes.contains($0.type ?? "") }
            if !searchText.isEmpty {
                result = result.filter {
                    ($0.name ?? "").localizedCaseInsensitiveContains(searchText) ||
                    ($0.nameEn ?? "").localizedCaseInsensitiveContains(searchText)
                }
            }
            // 稳定排序（同优先级内保持原序）
            let sorted = result.enumerated()
                .sorted { a, b in
                    let pa = Self.markerPriority(a.element.type ?? "")
                    let pb = Self.markerPriority(b.element.type ?? "")
                    if pa != pb { return pa < pb }
                    return a.offset < b.offset
                }
            sortedPoolCache = sorted.map(\.element)
            sortedPoolKey = key
        }
        let pool = sortedPoolCache

        // ── 数量足够 → 直接返回（正常模式恒返回全量核心标记）──
        guard pool.count > cap else { return pool }

        // ── 分层裁剪：核心类型始终保留，其余均匀抽样保证空间不聚簇 ──
        let keptCore = pool.filter { Self.markerPriority($0.type ?? "") == 0 }
        let others = pool.filter { Self.markerPriority($0.type ?? "") > 0 }
        var out = keptCore
        let room = max(0, cap - out.count)
        if room > 0, !others.isEmpty {
            let step = Double(others.count) / Double(room)
            var idx = 0.0
            while idx < Double(others.count), out.count < cap {
                out.append(others[Int(idx)])
                idx += step
            }
        }
        return out
    }

    /// 标记类型渲染优先级（数字越小越靠前保留）：
    ///   core 导航层（waypoint/tower/region/phone-booth/BOSS）恒显示；
    ///   其余收集类按缩放裁剪。
    private static func markerPriority(_ type: String) -> Int {
        switch type {
        case "waypoint", "tower", "region", "phone-booth", "boss": return 0
        case "quest", "activity", "viewpoint", "service", "shop": return 1
        default: return 2   // 材料/宝箱/谕石/收集品/神秘箱/货币…
        }
    }

    /// 单个标记视图
    @ViewBuilder
    private func markerView(_ m: MapMarker, renderW: CGFloat, renderH: CGFloat) -> some View {
        let px = CGFloat(m.safeX / 100.0) * renderW
        let py = CGFloat(m.safeY / 100.0) * renderH
        let mType = m.type ?? "unknown"
        let cat = categories.first { $0.id == mType }
        let color = cat?.color ?? defaultColor(for: mType)
        let isSel = selectedMarker == m
        let isRegion = mType == "region"
        let isBoss = mType == "boss"
        let isWaypoint = mType == "waypoint"
        let isTower = mType == "tower"
        // 标记尺寸根据缩放动态调整，确保低缩放也可见
        let baseSize: CGFloat = max(7, min(14, 5 + scale * 30))
        let dotSize: CGFloat = isWaypoint ? baseSize * 1.3 : (isBoss ? baseSize * 1.4 : baseSize)
        // 核心标记（传送点/塔/区域）始终显示中文标签，其他类型缩放足够大才显示
        let showLabel = isSel || isRegion || isWaypoint || isTower || isBoss || scale > 0.3

        // 区域名：大号文字标签（半透明发光）
        if isRegion {
            Text(m.displayName)
                .font(.system(size: max(13, 20 * scale * 1.4), weight: .heavy, design: .rounded))
                .foregroundStyle(color)
                .shadow(color: color.opacity(0.8), radius: 6)
                .shadow(color: .black, radius: 3)
                .position(x: px, y: py)
                .onTapGesture {
                    selectedMarker = (selectedMarker == m) ? nil : m
                }
        } else {
            // 普通标记：圆点 + 选中态光晕 + 可选标签
            ZStack {
                // 选中时的外圈呼吸光环
                if isSel {
                    Circle()
                        .stroke(color.opacity(0.4), lineWidth: 1.5)
                        .frame(width: dotSize * 2.2, height: dotSize * 2.2)
                        .shadow(color: color, radius: 8)
                }

                // 主圆点
                Circle()
                    .fill(color)
                    .frame(width: isSel ? dotSize * 1.4 : dotSize,
                           height: isSel ? dotSize * 1.4 : dotSize)
                    .shadow(color: color.opacity(0.9), radius: isSel ? 6 : 2)
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.85), lineWidth: 0.8)
                            .frame(width: isSel ? dotSize * 1.4 : dotSize,
                                   height: isSel ? dotSize * 1.4 : dotSize)
                    )

                // 中文标签（传送点/塔始终显示，其他缩放足够大才显示）
                if showLabel {
                    Text(m.labelName)
                        .font(.system(size: max(9, 11 * scale * 1.1), weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.black.opacity(0.75))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(color.opacity(0.4), lineWidth: 0.5)
                                )
                        )
                        .offset(y: isSel ? -14 : -10)
                }
            }
            .position(x: px, y: py)
            .onTapGesture {
                selectedMarker = (selectedMarker == m) ? nil : m
            }
        }
    }

    // MARK: - 顶部工具条

    private var topBar: some View {
        HStack(spacing: 14) {
            // ── 标题（青色发光）──
            HStack(spacing: 6) {
                Image(systemName: "map.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.cyan)
                Text("异环地图")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: Theme.cyan.opacity(0.5), radius: 3)
            }

            Spacer()

            // ── 搜索框（筛选/选图模式显示）──
            if mode != .normal {
                searchBar
                    .transition(.scale.combined(with: .opacity))
            }

            // ── 图层开关按钮（常驻，点一下从右侧拉下图层面板）──
            layerToggleButton

            // ── 缩放控制 ──
            HStack(spacing: 4) {
                zoomButton("minus") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scale = max(scale * 0.75, 0.08); lastScale = scale
                    }
                }
                Text("\(Int(scale * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 38)
                zoomButton("plus") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scale = min(scale * 1.3, 3.0); lastScale = scale
                    }
                }
                Divider().frame(height: 16).overlay(Theme.cyan.opacity(0.2))
                zoomButton("location.fill") {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        scale = 0.22; lastScale = 0.22
                        offset = .zero; lastOffset = .zero
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial).opacity(0.75)
                // 底部青色细描边
                Rectangle()
                    .fill(Theme.cyan.opacity(0.15))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        )
    }

    /// 三模式分段控件（精致胶囊样式）
    private var modeSegmentedControl: some View {
        HStack(spacing: 2) {
            ForEach(MapMode.allCases) { m in
                modeSegment(m)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    /// 单个模式分段
    private func modeSegment(_ m: MapMode) -> some View {
        let isActive = mode == m
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                mode = m
                // 切到正常模式时清空选中
                if m == .normal { selectedMarker = nil }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: m.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(m.rawValue)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(isActive ? .white : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                ZStack {
                    if isActive {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    colors: [Theme.cyan.opacity(0.35), Theme.cyan.opacity(0.15)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Theme.cyan.opacity(0.5), lineWidth: 0.8)
                            )
                            .shadow(color: Theme.cyan.opacity(0.3), radius: 4)
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .help(m.subtitle)
    }

    /// 搜索框
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.cyan.opacity(0.7))
            TextField("搜索地名 / 材料…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 140)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(searchText.isEmpty
                                ? Color.white.opacity(0.08)
                                : Theme.cyan.opacity(0.4),
                                lineWidth: 0.8)
                )
        )
    }

    /// 缩放按钮
    private func zoomButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.cyan)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .overlay(Circle().stroke(Color.white.opacity(0.06), lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // ── 侧边栏标题 ──
                sidebarHeader

                if mode == .filter {
                    // 筛选模式：分类 / 索引 双 tab
                    sidebarTabSwitcher
                    if sidebarTab == .categories {
                        filterContent
                    } else {
                        indexContent
                    }
                } else {
                    // 选图模式：区域列表
                    selectMapContent
                }
            }
            .padding(.bottom, 40)
        }
    }

    /// 侧边栏顶部标题
    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            // 模式图标 + 渐变背景
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [Theme.cyan.opacity(0.25), Theme.cyan.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.cyan.opacity(0.4), lineWidth: 0.6)
                    )
                    .frame(width: 28, height: 28)
                Image(systemName: mode == .filter ? "line.3.horizontal.decrease.circle" : "square.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.cyan)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(mode == .filter ? "分类筛选" : "区域选择")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(mode.subtitle)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
                    .tracking(0.5)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 56)
        .padding(.bottom, 14)
    }

    /// 侧边栏 tab 切换（分类 / 索引）
    private var sidebarTabSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(SidebarTab.allCases) { tab in
                let isActive = sidebarTab == tab
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        sidebarTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(isActive ? .white : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isActive ? Theme.cyan.opacity(0.25) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(0.05))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: 筛选模式 - 分类列表

    /// 筛选模式内容
    private var filterContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            // ── 全选/全不选 + 统计 ──
            HStack(spacing: 8) {
                Button {
                    withAnimation { for i in categories.indices { categories[i].isEnabled = true } }
                } label: {
                    Text("全选")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.cyan.opacity(0.12)))
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation { for i in categories.indices { categories[i].isEnabled = false } }
                } label: {
                    Text("清空")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.05)))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("\(categories.filter { $0.isEnabled }.reduce(0) { $0 + $1.count }) 项")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            // ── 分类列表 ──
            ForEach($categories) { $cat in
                categoryRow($cat)
            }

            Spacer(minLength: 30)
        }
    }

    /// 单个分类行（精致卡片样式）
    private func categoryRow(_ cat: Binding<MarkerCategory>) -> some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                cat.wrappedValue.isEnabled.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                // 颜色指示器（左侧色条 + 圆点）
                RoundedRectangle(cornerRadius: 2)
                    .fill(cat.wrappedValue.color)
                    .frame(width: 3, height: 22)
                    .shadow(color: cat.wrappedValue.color.opacity(0.6), radius: 3)
                    .opacity(cat.wrappedValue.isEnabled ? 1 : 0.3)

                // 图标
                ZStack {
                    Circle()
                        .fill(cat.wrappedValue.color.opacity(cat.wrappedValue.isEnabled ? 0.2 : 0.05))
                        .frame(width: 24, height: 24)
                    Image(systemName: cat.wrappedValue.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(cat.wrappedValue.isEnabled ? cat.wrappedValue.color : Theme.textTertiary)
                }

                // 标签 + 数量
                VStack(alignment: .leading, spacing: 1) {
                    Text(cat.wrappedValue.label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(cat.wrappedValue.isEnabled ? .white : Theme.textSecondary)
                    Text("\(cat.wrappedValue.count) 个标记")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer()

                // 自定义开关（更精致）
                ZStack {
                    Capsule()
                        .fill(cat.wrappedValue.isEnabled
                              ? cat.wrappedValue.color.opacity(0.4)
                              : Color.white.opacity(0.1))
                        .frame(width: 30, height: 16)
                        .overlay(
                            Capsule()
                                .stroke(cat.wrappedValue.isEnabled
                                        ? cat.wrappedValue.color.opacity(0.6)
                                        : Color.white.opacity(0.1),
                                        lineWidth: 0.5)
                        )
                    Circle()
                        .fill(cat.wrappedValue.isEnabled ? .white : Theme.textTertiary)
                        .frame(width: 11, height: 11)
                        .shadow(color: .black.opacity(0.3), radius: 1)
                        .offset(x: cat.wrappedValue.isEnabled ? 6 : -6)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: cat.wrappedValue.isEnabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(cat.wrappedValue.isEnabled
                          ? cat.wrappedValue.color.opacity(0.06)
                          : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    // MARK: - 常驻图层浮层

    /// 顶部工具栏的图层开关按钮（📑）
    private var layerToggleButton: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                layersOpen.toggle()
            }
        } label: {
            Image(systemName: layersOpen ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(layersOpen ? Theme.cyan : Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(layersOpen ? Theme.cyan.opacity(0.15) : Color.white.opacity(0.08))
                        .overlay(Circle().stroke(layersOpen ? Theme.cyan.opacity(0.4) : Color.white.opacity(0.06), lineWidth: 0.6))
                )
                .shadow(color: layersOpen ? Theme.cyan.opacity(0.4) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
        .help("图层（随时开关各收集层）")
    }

    /// 图层浮层面板（从右侧弹簧拉下，列出所有图层，可单独开关 + 全选/清空）
    private var layerPanel: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // ── 标题 ──
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    colors: [Theme.cyan.opacity(0.25), Theme.cyan.opacity(0.05)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Theme.cyan.opacity(0.4), lineWidth: 0.6)
                            )
                            .frame(width: 28, height: 28)
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.cyan)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("图层")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("随时开关 · 全收集叠加")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 56)
                .padding(.bottom, 14)

                // ── 全选/清空 + 统计 ──
                HStack(spacing: 8) {
                    Button {
                        withAnimation { for i in categories.indices { categories[i].isEnabled = true } }
                    } label: {
                        Text("全选")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.cyan.opacity(0.12)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation { for i in categories.indices { categories[i].isEnabled = false } }
                    } label: {
                        Text("清空")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("\(categories.filter { $0.isEnabled }.reduce(0) { $0 + $1.count }) 项")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                // ── 分类列表（与筛选侧栏共用 categoryRow）──
                ForEach($categories) { $cat in
                    categoryRow($cat)
                }

                Spacer(minLength: 30)
            }
            .padding(.bottom, 40)
        }
    }

    // MARK: 筛选模式 - 索引列表

    /// 索引内容（按首字母/字符分组列出所有可搜索的标记）
    private var indexContent: some View {
        let totalIndexed = indexGroupedMarkers.values.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 0) {
            // ── 索引提示 ──
            HStack(spacing: 6) {
                Image(systemName: "textformat")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.cyan.opacity(0.7))
                Text("按拼音/字母索引")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
                    .tracking(0.5)
                Spacer()
                Text("\(totalIndexed) 项")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            // ── 字母快速跳转条 ──
            indexJumpBar

            // ── 分组列表 ──
            ForEach(indexGroupedMarkers.keys.sorted(), id: \.self) { key in
                if let items = indexGroupedMarkers[key], !items.isEmpty {
                    indexSectionHeader(key)
                    ForEach(items.prefix(40)) { m in
                        indexRow(m)
                    }
                    if items.count > 40 {
                        Text("… 还有 \(items.count - 40) 项")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 4)
                    }
                }
            }

            Spacer(minLength: 30)
        }
    }

    /// 字母快速跳转条
    private var indexJumpBar: some View {
        HStack(spacing: 2) {
            ForEach(indexGroupedMarkers.keys.sorted(), id: \.self) { key in
                Text(key)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.cyan.opacity(0.8))
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.04))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// 索引分组标题
    private func indexSectionHeader(_ key: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.cyan)
                .shadow(color: Theme.cyan.opacity(0.4), radius: 2)
            Rectangle()
                .fill(Theme.cyan.opacity(0.15))
                .frame(height: 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// 索引单行
    private func indexRow(_ m: MapMarker) -> some View {
        Button {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                selectedMarker = m
                // 缩放到该标记
                zoomToMarker(m)
            }
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(categories.first { $0.id == m.type }?.color ?? Theme.cyan)
                    .frame(width: 5, height: 5)
                Text(m.displayName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Text(categories.first { $0.id == m.type }?.label ?? "")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(selectedMarker == m ? Theme.cyan.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    /// 索引分组后的标记（按 indexKey 分组）
    private var indexGroupedMarkers: [String: [MapMarker]] {
        guard let db = db else { return [:] }
        // 索引只在已启用分类的标记中建立
        let enabledTypes = Set(categories.filter { $0.isEnabled }.map { $0.id })
        let all: [MapMarker]
        if mode == .filter {
            all = (db.markers_all ?? []).filter { enabledTypes.contains($0.type ?? "") }
        } else {
            all = (db.markers_all ?? [])
        }
        // 搜索过滤
        let filtered = searchText.isEmpty ? all : all.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(searchText) ||
            ($0.nameEn ?? "").localizedCaseInsensitiveContains(searchText)
        }
        // 按 indexKey 分组
        var grouped: [String: [MapMarker]] = [:]
        for m in filtered {
            grouped[m.indexKey, default: []].append(m)
        }
        return grouped
    }

    // MARK: 选图模式 - 区域列表

    /// 选择地图模式内容
    private var selectMapContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            let regions: [(key: String, zh: String, color: Color, icon: String)] = [
                ("new-herland",      "新赫兰德",   .blue,    "building.2.fill"),
                ("bridge-crossings",  "桥间地",     .purple,  "bridge.fill"),
                ("miguel-district",   "米格尔区",   .green,   "tree.fill"),
                ("illusion-town",     "幻镇",       .orange,  "sparkles"),
                ("unheard-shores",    "未闻浦",     .cyan,    "water.waves"),
            ]

            ForEach(regions, id: \.key) { r in
                regionRow(r)
            }

            Spacer(minLength: 30)

            // ── 当前区域信息卡 ──
            if let sel = selectedRegion, let db = db {
                let count = (db.markers_all ?? []).filter { $0.region == sel }.count
                let regionInfo = regions.first { $0.key == sel }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("当前区域")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(1.5)
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Image(systemName: "location.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.cyan)
                    }
                    Text(regionInfo?.zh ?? sel)
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.cyan)
                        Text("\(count) 个标记点")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: [Theme.cyan.opacity(0.1), Color.white.opacity(0.03)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Theme.cyan.opacity(0.25), lineWidth: 0.8)
                        )
                )
                .padding(.horizontal, 12)
            }
        }
    }

    /// 单个区域行
    private func regionRow(_ r: (key: String, zh: String, color: Color, icon: String)) -> some View {
        let isActive = selectedRegion == r.key
        return Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                selectedRegion = r.key
                zoomToRegion(r.key)
            }
        } label: {
            HStack(spacing: 12) {
                // 区域图标 + 渐变背景
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [r.color.opacity(isActive ? 0.4 : 0.2), r.color.opacity(0.05)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(r.color.opacity(isActive ? 0.6 : 0.2), lineWidth: 0.8)
                        )
                        .frame(width: 36, height: 36)
                    Image(systemName: r.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(r.color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(r.zh)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(isActive ? .white : Theme.textSecondary)
                    Text(regionMarkerCount(r.key))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.cyan)
                        .shadow(color: Theme.cyan.opacity(0.5), radius: 3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? r.color.opacity(0.1) : Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isActive ? r.color.opacity(0.3) : Color.white.opacity(0.04),
                                    lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    /// 区域标记数量
    private func regionMarkerCount(_ key: String) -> String {
        guard let db = db else { return "0 个标记" }
        let count = (db.markers_all ?? []).filter { $0.region == key }.count
        return "\(count) 个标记"
    }

    // MARK: - 标记详情浮窗

    /// 选中标记的详情卡片（右下角浮窗）
    private func markerDetailCard(_ m: MapMarker) -> some View {
        let mType = m.type ?? "unknown"
        let cat = categories.first { $0.id == mType }
        let color = cat?.color ?? Theme.cyan

        return HStack {
            Spacer()
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    // 左侧色块 + 图标
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(
                                    colors: [color.opacity(0.35), color.opacity(0.08)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(color.opacity(0.5), lineWidth: 0.8)
                            )
                            .frame(width: 44, height: 44)
                        Image(systemName: cat?.icon ?? "mappin")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(color)
                    }

                    // 中间信息
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.displayName)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            // 类型标签
                            Text(cat?.label ?? mType)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(color.opacity(0.18)))
                            // 坐标
                            HStack(spacing: 3) {
                                Image(systemName: "location")
                                    .font(.system(size: 8))
                                Text("(\(String(format: "%.1f", m.safeX)), \(String(format: "%.1f", m.safeY)))")
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundStyle(Theme.textSecondary)
                            // 区域
                            if let reg = m.region, !reg.isEmpty {
                                HStack(spacing: 3) {
                                    Image(systemName: "globe")
                                        .font(.system(size: 8))
                                    Text(reg)
                                        .font(.system(size: 10, design: .rounded))
                                }
                                .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }

                    Spacer(minLength: 12)

                    // 关闭按钮
                    Button {
                        withAnimation { selectedMarker = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 380)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.ultraThinMaterial.opacity(0.95))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(color.opacity(0.35), lineWidth: 1)
                        )
                        .shadow(color: color.opacity(0.2), radius: 12)
                )
                .padding(16)
            }
        }
    }

    // MARK: - 缩放定位

    /// 缩放到指定区域中心
    private func zoomToRegion(_ key: String) {
        guard let db = db else { return }
        let markers = (db.markers_all ?? []).filter { $0.region == key }
        guard !markers.isEmpty else { return }

        let avgX = markers.reduce(0.0) { $0 + $1.safeX } / Double(markers.count)
        let avgY = markers.reduce(0.0) { $0 + $1.safeY } / Double(markers.count)

        // 适度放大以聚焦区域
        if scale < 0.35 {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                scale = 0.4
                lastScale = 0.4
            }
        }

        let renderW = mapSize * scale
        let renderH = renderW / mapAspect
        let targetPx = CGFloat(avgX / 100.0) * renderW
        let targetPy = CGFloat(avgY / 100.0) * renderH

        // 屏幕中心（假设窗口约 900x600，侧边栏占 300）
        let centerX: CGFloat = 450 + 150
        let centerY: CGFloat = 300
        offset = CGSize(width: centerX - targetPx, height: centerY - targetPy)
        lastOffset = offset
    }

    /// 缩放到指定标记
    private func zoomToMarker(_ m: MapMarker) {
        if scale < 0.5 {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                scale = 0.6
                lastScale = 0.6
            }
        }
        let renderW = mapSize * scale
        let renderH = renderW / mapAspect
        let targetPx = CGFloat(m.safeX / 100.0) * renderW
        let targetPy = CGFloat(m.safeY / 100.0) * renderH
        let centerX: CGFloat = 450 + 150
        let centerY: CGFloat = 300
        offset = CGSize(width: centerX - targetPx, height: centerY - targetPy)
        lastOffset = offset
    }

    // MARK: - 底部状态栏

    private var bottomStatusBar: some View {
        HStack(spacing: 14) {
            // 选中标记信息（紧凑版）
            if let m = selectedMarker {
                HStack(spacing: 6) {
                    Circle()
                        .fill(categories.first { $0.id == m.type }?.color ?? Theme.cyan)
                        .frame(width: 6, height: 6)
                        .shadow(color: Theme.cyan.opacity(0.5), radius: 2)
                    Text(m.displayName)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("(\(String(format: "%.1f", m.safeX)), \(String(format: "%.1f", m.safeY)))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.cyan.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Theme.cyan.opacity(0.25), lineWidth: 0.5)
                        )
                )
            }

            // 标记统计
            if let db = db {
                HStack(spacing: 4) {
                    Image(systemName: "circle.grid.2x2.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.cyan.opacity(0.6))
                    Text("\(filteredMarkers(db: db).count) / \(db.summary?.total_markers ?? 5677)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer()

            // 图例（紧凑）
            HStack(spacing: 10) {
                ForEach(categories.filter { $0.isEnabled }.prefix(6)) { cat in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(cat.color)
                            .frame(width: 5, height: 5)
                            .shadow(color: cat.color.opacity(0.5), radius: 1.5)
                        Text(cat.label)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial).opacity(0.65)
                Rectangle()
                    .fill(Theme.cyan.opacity(0.12))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        )
    }

    // MARK: - 数据加载

    private func loadData() {
        // 巨图（11264² PNG）解码移到后台，主线程零解码阻塞，只回写加载态
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // 1. 后台解码底图（优先 bigworldmapSecond.png，缺失时回退到旧游戏地图）
            var decoded: NSImage?
            if FileManager.default.fileExists(atPath: mapImagePath) {
                decoded = NSImage(contentsOfFile: mapImagePath)
            } else if FileManager.default.fileExists(atPath: altMapImagePath) {
                decoded = NSImage(contentsOfFile: altMapImagePath)
            }

            // 1b. 标记数据库（7.5MB JSON）也挪到后台解码 —— 主线程只接收解码结果，
            // 避免地图首次打开时 JSONDecoder 阻塞 UI 几十毫秒（可感知掉帧）。
            var decodedDb: MapDatabase?
            if FileManager.default.fileExists(atPath: dataPath) {
                do {
                    let raw = try Data(contentsOf: URL(fileURLWithPath: dataPath))
                    decodedDb = try JSONDecoder().decode(MapDatabase.self, from: raw)
                } catch {
                    print("⚠️ 地图数据库加载失败: \(error)")
                }
            }

            DispatchQueue.main.async {
                // 2. 主线程回写图片 + 尺寸
                if let img = decoded {
                    mapImage = img
                    mapSize = img.size.width
                    mapAspect = img.size.width / max(img.size.height, 1)
                }

                // 3. 主线程回写数据库 + 构建分类
                if let dbData = decodedDb {
                    db = dbData
                    buildCategories()
                }

                // 4. 默认选中新赫兰德
                if selectedRegion == nil { selectedRegion = "new-herland" }

                // 5. 计算初始 offset 让数据区域居中
                // 数据范围 x:25-85, y:5-75 → 中心 x=55%, y=40%
                centerOnDataRegion()

                // 6. 加载完成，关闭加载动画
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        isLoading = false
                    }
                }
            }
        }
    }

    /// 计算偏移让数据区域中心居中显示
    private func centerOnDataRegion() {
        let renderW = mapSize * scale
        let renderH = renderW / mapAspect
        // 数据中心在底图坐标 (55%, 40%)
        let dataCenterX = renderW * 0.55
        let dataCenterY = renderH * 0.40
        // 窗口尺寸（地图卡片区域约 1163×680）
        let winW: CGFloat = 1163
        let winH: CGFloat = 680
        // offset = 窗口中心 - 数据中心
        let newOffset = CGSize(
            width: winW / 2 - dataCenterX,
            height: winH / 2 - dataCenterY
        )
        offset = newOffset
        lastOffset = newOffset
    }

    /// 从数据库构建分类列表（使用 categoryDefs，从 markers_all 按 type 统计）
    private func buildCategories() {
        guard let db = db else { return }

        let all = db.markers_all ?? []
        let typeColors = db.marker_types ?? [:]
        // 核心导航层默认开启，收集类默认关闭
        let coreTypes: Set<String> = ["waypoint", "region", "phone-booth", "tower"]

        categories = Self.categoryDefs.map { d in
            // 从 markers_all 按 type 统计数量
            let count = all.filter { $0.type == d.id }.count

            // 颜色：优先用 marker_types 的颜色，否则用预设
            let hexColor = typeColors[d.id]?.color
            let color: Color
            if let hex = hexColor, !hex.isEmpty {
                color = MarkerCategory.parseColor(hex)
            } else {
                color = defaultColor(for: d.id)
            }

            return MarkerCategory(
                id: d.id,
                label: d.label,
                color: color,
                icon: d.icon,
                // 打开地图默认只开核心导航层（传送点/区域/电话亭/塔），
                // 收集类图层（材料/宝箱/谕石/收集品…）默认关闭，全收集时在图层浮层手动开启。
                isEnabled: coreTypes.contains(d.id),
                count: count
            )
        }
    }

    /// 各类型的默认颜色（marker_types 缺失时回退）
    private func defaultColor(for type: String) -> Color {
        switch type {
        case "waypoint":     return Color(red: 0.92, green: 0.70, blue: 0.03)  // 黄
        case "region":       return Color(red: 0.42, green: 0.45, blue: 0.50)  // 灰
        case "phone-booth":  return Color(red: 0.02, green: 0.71, blue: 0.83)  // 青
        case "tower":        return Color(red: 0.96, green: 0.62, blue: 0.04)  // 橙
        case "boss":         return Color(red: 0.94, green: 0.27, blue: 0.27)  // 红
        case "quest":        return Color(red: 0.23, green: 0.51, blue: 0.96)  // 蓝
        case "activity":     return Color(red: 0.93, green: 0.28, blue: 0.60)  // 粉
        case "viewpoint":    return Color(red: 0.02, green: 0.72, blue: 0.83)  // 青
        case "service":      return Color(red: 0.08, green: 0.72, blue: 0.55)  // 青绿
        case "shop":         return Color(red: 0.02, green: 0.71, blue: 0.83)  // 青
        case "oracle-stone": return Color(red: 0.65, green: 0.55, blue: 0.98)  // 紫(玉石)
        case "chest":        return Color(red: 0.96, green: 0.62, blue: 0.04)  // 橙
        case "collectible":  return Color(red: 0.13, green: 0.77, blue: 0.37)  // 绿
        case "mystery-box":  return Color(red: 0.49, green: 0.23, blue: 0.93)  // 紫
        case "gift-21":      return Color(red: 0.96, green: 0.45, blue: 0.71)  // 粉
        case "currency":     return Color(red: 0.98, green: 0.80, blue: 0.08)  // 黄
        case "arc-plate":    return Color(red: 0.55, green: 0.36, blue: 0.96)  // 紫
        case "monster":      return Color(red: 0.86, green: 0.15, blue: 0.15)  // 红
        default:             return Theme.cyan
        }
    }
}

// MARK: - 地图入口按钮

/// 可嵌入侧边栏的地图卡片
struct GameMapCard: View {
    @State private var showMap = false  // 默认关闭，由用户点「打开异环地图」才弹出

    var body: some View {
        GlowCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "MAP")

                Button {
                    showMap = true
                } label: {
                    HStack {
                        Image(systemName: "map.fill")
                            .font(.system(size: 13))
                        Text("打开异环地图")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .foregroundStyle(Theme.cyan)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                }
                .buttonStyle(.plain)

                Text("三模式 · 5677标记 · 传送/材料/BOSS")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .sheet(isPresented: $showMap) {
            GameMapView()
                .frame(minWidth: 1100, minHeight: 720)
        }
    }
}
