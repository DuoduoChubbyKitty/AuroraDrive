// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import Foundation

// MARK: - 数据模型

struct GradientIcon: View {
    let icon: String
    var body: some View {
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
            Image(systemName: icon)
                .font(FontStyle.semibold)
                .foregroundStyle(Theme.cyan)
        }
    }
}

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

    enum CodingKeys: String, CodingKey {
        case name, nameEn, type, x, y, subtype, region, icon, link
    }

    var displayName: String {
        let raw = name ?? nameEn ?? "?"
        return raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                   .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var labelName: String {
        let t = type ?? ""
        switch t {
        case "waypoint":
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
            return displayName
        default:
            return displayName
        }
    }

    var safeX: Double { x ?? 50.0 }
    var safeY: Double { y ?? 50.0 }

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

enum MapMode: String, CaseIterable, Identifiable {
    case normal    = "正常地图"
    case filter    = "按种类筛选"
    case selectMap = "选择地图"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .normal:    return "map"
        case .filter:    return "line.3.horizontal.decrease.circle"
        case .selectMap: return "square.grid.2x2"
        }
    }

    var subtitle: String {
        switch self {
        case .normal:    return "传送点 · 地名"
        case .filter:    return "材料 · BOSS · 怪物"
        case .selectMap: return "区域 · 快速定位"
        }
    }
}

// MARK: - 分类配置

struct MarkerCategory: Identifiable, Hashable {
    let id: String
    let label: String
    let color: Color
    let icon: String
    var isEnabled: Bool
    var count: Int
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

// MARK: - 辅助视图

struct SpinningRing: View {
    let size: CGFloat
    let ringWidth: CGFloat
    let bgOpacity: CGFloat
    let spinColor: any ShapeStyle
    let duration: Double
    let track: Any

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.cyan.opacity(bgOpacity), lineWidth: ringWidth)
                .frame(width: size, height: size)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(spinColor, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))
                .rotationEffect(.degrees(360))
                .animation(.linear(duration: duration).repeatForever(autoreverses: false), value: track)
        }
    }
}

struct SlidePanel: View {
    let edge: Edge
    let content: () -> any View
    let background: () -> any View

    var body: some View {
        content()
            .frame(width: 300)
            .background(background())
            .transition(.move(edge: edge).combined(with: .opacity))
    }
}

// MARK: - 动画常量

private let slideAnim = Animation.spring(response: 0.42, dampingFraction: 0.86)
private let zoomAnim = Animation.spring(response: 0.5, dampingFraction: 0.85)
private let selectionAnim = Animation.spring(response: 0.4, dampingFraction: 0.85)
private let tabAnim = Animation.spring(response: 0.3, dampingFraction: 0.85)
private let quickOutAnim = Animation.easeOut(duration: 0.2)
private let closeAnim = Animation.easeIn(duration: 0.18)
private let modeSwitchAnim = Animation.spring(response: 0.35, dampingFraction: 0.82)
private let toggleAnim = Animation.spring(response: 0.25, dampingFraction: 0.9)
private let locateAnim = Animation.spring(response: 0.5, dampingFraction: 0.8)
private let layersAnim = Animation.spring(response: 0.42, dampingFraction: 0.86)
private let markerAnim = Animation.spring(response: 0.3, dampingFraction: 0.85)
private let catToggleAnim = Animation.spring(response: 0.25, dampingFraction: 0.8)
private let fadeOutAnim = Animation.easeOut(duration: 0.3)

// MARK: - 内边距辅助

extension View {
    func ph8v3() -> some View { padding(.horizontal, 8).padding(.vertical, 3) }
    func ph10v5() -> some View { padding(.horizontal, 10).padding(.vertical, 5) }
}

// MARK: - 主视图

struct GameMapView: View {
    private let modelsRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("models")
    }()

    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 0.11
    @State private var lastScale: CGFloat = 0.11
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    @State private var db: MapDatabase?
    @State private var mapImage: NSImage?
    @State private var mapSize: CGFloat = 3840
    static let viewCenterX: CGFloat = 600  // 450 + 150, 定位十字准心 X
    static let viewCenterY: CGFloat = 300  // 定位十字准心 Y
    static let winW: CGFloat = 1163
    static let winH: CGFloat = 680
    @State private var mapAspect: CGFloat = 16.0 / 9.0
    @State private var isLoading: Bool = true

    @State private var mode: MapMode = .normal

    @State private var categories: [MarkerCategory] = []

    @State private var selectedMarker: MapMarker?
    @State private var searchText: String = ""
    @State private var selectedRegion: String?

    @State private var isClosing: Bool = false

    @State private var sortedPoolCache: [MapMarker] = []
    @State private var sortedPoolKey: String = ""
    @State private var sortedPoolCapKey: Int = 0  // cap 缓存键，排序结果变化时重置为 0
    @State private var filteredPoolCache: [MapMarker] = []

    @State private var sidebarTab: SidebarTab = .categories

    @State private var layersOpen: Bool = false

    enum SidebarTab: String, CaseIterable, Identifiable {
        case categories = "分类"
        case index      = "索引"
        var id: String { rawValue }
    }

    private let normalModeTypes: Set<String> = ["waypoint", "phone-booth", "tower", "region"]

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
        ("oracle-stone", "谕石(玉石)",   "gem.fill"),
        ("chest",        "宝箱",         "shippingbox.fill"),
        ("collectible",  "收集品",       "sparkles"),
        ("mystery-box",  "神秘箱",       "questionmark.diamond.fill"),
        ("gift-21",      "「21」的赠礼",  "gift.fill"),
        ("currency",     "货币战利品",    "dollarsign.circle.fill"),
        ("arc-plate",    "弧盘",         "circle.hexagongrid.fill"),
        ("monster",      "怪物",         "ant.fill"),
    ]

    var body: some View {
        ZStack {
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

            mapCanvas

            VStack(spacing: 0) {
                topBar
                Spacer()
                if mode != .normal { bottomStatusBar }
            }
            .zIndex(10)

            HStack(spacing: 0) {
                if mode != .normal { SlidePanel(edge: .leading, background: { sidebarBackground }) { sidebar } }
                Spacer()
            }
            .zIndex(20)
            .animation(slideAnim, value: mode)

            HStack(spacing: 0) {
                Spacer()
                if layersOpen { SlidePanel(edge: .trailing, background: { sidebarBackground }) { layerPanel } }
            }
            .zIndex(25)
            .animation(layersAnim, value: layersOpen)

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

            // hitTest穿透：不能用allowsHitTesting(false)包裹否则按钮也点不到
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

            if let m = selectedMarker {
                markerDetailCard(m)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .zIndex(50)
            }

            if isLoading {
                ZStack {
                    Color.black.opacity(0.85).ignoresSafeArea()
                    VStack(spacing: 18) {
                        SpinningRing(size: 56, ringWidth: 3, bgOpacity: 0.15,
                                     spinColor: AngularGradient(
                                         gradient: Gradient(colors: [Theme.cyan, Theme.cyan.opacity(0.3), .clear]),
                                         center: .center),
                                     duration: 0.9, track: isLoading)
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
            // P1修复：关闭地图sheet时释放8636×8592巨图（解码后≈280MB常驻）避免反复开合内存累积
            mapImage = nil
            db = nil
        }
        .animation(markerAnim, value: selectedMarker)
        .animation(selectionAnim, value: mode)
    }

    private var closeButton: some View {
        Button {
            withAnimation(.easeIn(duration: 0.18)) {
                isClosing = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                dismiss()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.20))
                    .frame(width: 52, height: 52)
                    .shadow(color: .red.opacity(0.7), radius: 10)
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

    private var sidebarBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 0)
                .fill(.ultraThinMaterial.opacity(0.92))
            LinearGradient(
                colors: [Theme.cyan.opacity(0.08), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 120)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
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
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: mapSize * scale, height: mapSize * scale / mapAspect)
                            .clipped()
                            .overlay(
                                LinearGradient(
                                    colors: [.black.opacity(0.4), .clear, .clear, .black.opacity(0.4)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                                .allowsHitTesting(false)
                            )

                        markerLayer
                    }
                    .offset(offset)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .gesture(dragGesture)
                    .gesture(magnifyGesture)
                    .onTapGesture { location in
                        if selectedMarker != nil {
                            selectedMarker = nil
                        }
                    }
                }
            } else {
                VStack(spacing: 14) {
                    SpinningRing(size: 44, ringWidth: 2, bgOpacity: 0.2,
                                 spinColor: Theme.cyan, duration: 1.0, track: mapImage != nil)
                    Text("加载地图数据中…")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .tracking(1)
                }
            }
        }
    }

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

    private func filteredMarkers(db: MapDatabase) -> [MapMarker] {
        let enabledTypes = Set(categories.filter { $0.isEnabled }.map { $0.id })
        guard !enabledTypes.isEmpty else { return [] }

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
            let sorted = result.enumerated()
                .sorted { a, b in
                    let pa = Self.markerPriority(a.element.type ?? "")
                    let pb = Self.markerPriority(b.element.type ?? "")
                    if pa != pb { return pa < pb }
                    return a.offset < b.offset
                }
            sortedPoolCache = sorted.map(\.element)
            sortedPoolKey = key
            sortedPoolCapKey = 0  // 排序结果变化，cap 缓存失效
        }

        // cap 变化时重新计算 filtered 结果（避免每帧重复 filter）
        if cap != sortedPoolCapKey {
            let pool = sortedPoolCache
            guard pool.count > cap else {
                filteredPoolCache = pool
                sortedPoolCapKey = cap
                return pool
            }
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
            filteredPoolCache = out
            sortedPoolCapKey = cap
            return out
        }

        return filteredPoolCache
    }

    private static func markerPriority(_ type: String) -> Int {
        switch type {
        case "waypoint", "tower", "region", "phone-booth", "boss": return 0
        case "quest", "activity", "viewpoint", "service", "shop": return 1
        default: return 2
        }
    }

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
        let baseSize: CGFloat = max(7, min(14, 5 + scale * 30))
        let dotSize: CGFloat = isWaypoint ? baseSize * 1.3 : (isBoss ? baseSize * 1.4 : baseSize)
        let showLabel = isSel || isRegion || isWaypoint || isTower || isBoss || scale > 0.3

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
            ZStack {
                if isSel {
                    Circle()
                        .stroke(color.opacity(0.4), lineWidth: 1.5)
                        .frame(width: dotSize * 2.2, height: dotSize * 2.2)
                        .shadow(color: color, radius: 8)
                }

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

            if mode != .normal {
                searchBar
                    .transition(.scale.combined(with: .opacity))
            }

            layerToggleButton

            HStack(spacing: 4) {
                zoomButton("minus") {
                    withAnimation(quickOutAnim) {
                        scale = max(scale * 0.75, 0.08); lastScale = scale
                    }
                }
                Text("\(Int(scale * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 38)
                zoomButton("plus") {
                    withAnimation(quickOutAnim) {
                        scale = min(scale * 1.3, 3.0); lastScale = scale
                    }
                }
                Divider().frame(height: 16).overlay(Theme.cyan.opacity(0.2))
                zoomButton("location.fill") {
                    withAnimation(locateAnim) {
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
                Rectangle()
                    .fill(Theme.cyan.opacity(0.15))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        )
    }

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

    private func modeSegment(_ m: MapMode) -> some View {
        let isActive = mode == m
        return Button {
            withAnimation(modeSwitchAnim) {
                mode = m
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
                sidebarHeader

                if mode == .filter {
                    sidebarTabSwitcher
                    if sidebarTab == .categories {
                        filterContent
                    } else {
                        indexContent
                    }
                } else {
                    selectMapContent
                }
            }
            .padding(.bottom, 40)
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            GradientIcon(icon: mode == .filter ? "line.3.horizontal.decrease.circle" : "square.grid.2x2")

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

    private var sidebarTabSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(SidebarTab.allCases) { tab in
                let isActive = sidebarTab == tab
                Button {
                    withAnimation(tabAnim) {
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

    private var filterContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            categoryToolbar
            ForEach($categories) { $cat in
                categoryRow($cat)
            }
            Spacer(minLength: 30)
        }
    }

    private var categoryToolbar: some View {
        HStack(spacing: 8) {
            Button { withAnimation { for i in categories.indices { categories[i].isEnabled = true } } } label: {
                Text("全选").font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.cyan).ph8v3()
                    .background(Capsule().fill(Theme.cyan.opacity(0.12)))
            }.buttonStyle(.plain)
            Button { withAnimation { for i in categories.indices { categories[i].isEnabled = false } } } label: {
                Text("清空").font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textTertiary).ph8v3()
                    .background(Capsule().fill(Color.white.opacity(0.05)))
            }.buttonStyle(.plain)
            Spacer()
            Text("\(categories.filter { $0.isEnabled }.reduce(0) { $0 + $1.count }) 项")
                .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Theme.textTertiary)
        }.padding(.horizontal, 16).padding(.bottom, 10)
    }

    private func categoryRow(_ cat: Binding<MarkerCategory>) -> some View {
        Button {
            withAnimation(toggleAnim) {
                cat.wrappedValue.isEnabled.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(cat.wrappedValue.color)
                    .frame(width: 3, height: 22)
                    .shadow(color: cat.wrappedValue.color.opacity(0.6), radius: 3)
                    .opacity(cat.wrappedValue.isEnabled ? 1 : 0.3)

                ZStack {
                    Circle()
                        .fill(cat.wrappedValue.color.opacity(cat.wrappedValue.isEnabled ? 0.2 : 0.05))
                        .frame(width: 24, height: 24)
                    Image(systemName: cat.wrappedValue.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(cat.wrappedValue.isEnabled ? cat.wrappedValue.color : Theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(cat.wrappedValue.label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(cat.wrappedValue.isEnabled ? .white : Theme.textSecondary)
                    Text("\(cat.wrappedValue.count) 个标记")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer()

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
                .animation(catToggleAnim, value: cat.wrappedValue.isEnabled)
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

    private var layerToggleButton: some View {
        Button {
            withAnimation(slideAnim) {
                layersOpen.toggle()
            }
        } label: {
            Image(systemName: layersOpen ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                .font(FontStyle.semibold)
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

    private var layerPanel: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    GradientIcon(icon: "square.stack.3d.up.fill")
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

                categoryToolbar
                ForEach($categories) { $cat in
                    categoryRow($cat)
                }
                Spacer(minLength: 30)
            }
            .padding(.bottom, 40)
        }
    }

    // MARK: 筛选模式 - 索引列表

    private var indexContent: some View {
        let totalIndexed = indexGroupedMarkers.values.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 0) {
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

            indexJumpBar

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

    private func indexRow(_ m: MapMarker) -> some View {
        Button {
            withAnimation(locateAnim) {
                selectedMarker = m
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

    private var indexGroupedMarkers: [String: [MapMarker]] {
        guard let db = db else { return [:] }
        let enabledTypes = Set(categories.filter { $0.isEnabled }.map { $0.id })
        let all: [MapMarker]
        if mode == .filter {
            all = (db.markers_all ?? []).filter { enabledTypes.contains($0.type ?? "") }
        } else {
            all = (db.markers_all ?? [])
        }
        let filtered = searchText.isEmpty ? all : all.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(searchText) ||
            ($0.nameEn ?? "").localizedCaseInsensitiveContains(searchText)
        }
        var grouped: [String: [MapMarker]] = [:]
        for m in filtered {
            grouped[m.indexKey, default: []].append(m)
        }
        return grouped
    }

    // MARK: 选图模式 - 区域列表

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

    private func regionRow(_ r: (key: String, zh: String, color: Color, icon: String)) -> some View {
        let isActive = selectedRegion == r.key
        return Button {
            withAnimation(selectionAnim) {
                selectedRegion = r.key
                zoomToRegion(r.key)
            }
        } label: {
            HStack(spacing: 12) {
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

    private func regionMarkerCount(_ key: String) -> String {
        guard let db = db else { return "0 个标记" }
        let count = (db.markers_all ?? []).filter { $0.region == key }.count
        return "\(count) 个标记"
    }

    // MARK: - 标记详情浮窗

    private func markerDetailCard(_ m: MapMarker) -> some View {
        let mType = m.type ?? "unknown"
        let cat = categories.first { $0.id == mType }
        let color = cat?.color ?? Theme.cyan

        return HStack {
            Spacer()
            VStack {
                Spacer()
                HStack(spacing: 12) {
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

                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.displayName)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(cat?.label ?? mType)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(color.opacity(0.18)))
                            HStack(spacing: 3) {
                                Image(systemName: "location")
                                    .font(.system(size: 8))
                                Text("(\(String(format: "%.1f", m.safeX)), \(String(format: "%.1f", m.safeY)))")
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundStyle(Theme.textSecondary)
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

    private func zoomToRegion(_ key: String) {
        guard let db = db else { return }
        let markers = (db.markers_all ?? []).filter { $0.region == key }
        guard !markers.isEmpty else { return }

        let avgX = markers.reduce(0.0) { $0 + $1.safeX } / Double(markers.count)
        let avgY = markers.reduce(0.0) { $0 + $1.safeY } / Double(markers.count)

        if scale < 0.35 {
            withAnimation(zoomAnim) {
                scale = 0.4
                lastScale = 0.4
            }
        }

        let renderW = mapSize * scale
        let renderH = renderW / mapAspect
        let targetPx = CGFloat(avgX / 100.0) * renderW
        let targetPy = CGFloat(avgY / 100.0) * renderH

        offset = CGSize(width: Self.viewCenterX - targetPx, height: Self.viewCenterY - targetPy)
        lastOffset = offset
    }

    private func zoomToMarker(_ m: MapMarker) {
        if scale < 0.5 {
            withAnimation(zoomAnim) {
                scale = 0.6
                lastScale = 0.6
            }
        }
        let renderW = mapSize * scale
        let renderH = renderW / mapAspect
        let targetPx = CGFloat(m.safeX / 100.0) * renderW
        let targetPy = CGFloat(m.safeY / 100.0) * renderH
        offset = CGSize(width: Self.viewCenterX - targetPx, height: Self.viewCenterY - targetPy)
        lastOffset = offset
    }

    // MARK: - 底部状态栏

    private var bottomStatusBar: some View {
        HStack(spacing: 14) {
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

            HStack(spacing: 10) {
                // 直接 index loop，避免 filter+prefix 产生中间 Array（UI 渲染路径）
                ForEach(Array(0..<categories.count).prefix(6), id: \.self) { i in
                    let cat = categories[i]
                    if cat.isEnabled {
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
        let mapImagePath = modelsRoot.appendingPathComponent("bigworldmapSecond.png").path
        let altMapImagePath = modelsRoot.appendingPathComponent("yihuan_map_z4.png").path
        let dataPath = modelsRoot.appendingPathComponent("FINAL_complete_map_database.json").path

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var decoded: NSImage?
            if FileManager.default.fileExists(atPath: mapImagePath) {
                decoded = NSImage(contentsOfFile: mapImagePath)
            } else if FileManager.default.fileExists(atPath: altMapImagePath) {
                decoded = NSImage(contentsOfFile: altMapImagePath)
            }

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
                if let img = decoded {
                    mapImage = img
                    mapSize = img.size.width
                    mapAspect = img.size.width / max(img.size.height, 1)
                }

                if let dbData = decodedDb {
                    db = dbData
                    buildCategories()
                }

                if selectedRegion == nil { selectedRegion = "new-herland" }

                centerOnDataRegion()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(fadeOutAnim) {
                        isLoading = false
                    }
                }
            }
        }
    }

    private func centerOnDataRegion() {
        let renderW = mapSize * scale
        let renderH = renderW / mapAspect
        let dataCenterX = renderW * 0.55
        let dataCenterY = renderH * 0.40
        let newOffset = CGSize(
            width: Self.winW / 2 - dataCenterX,
            height: Self.winH / 2 - dataCenterY
        )
        offset = newOffset
        lastOffset = newOffset
    }

    private func buildCategories() {
        guard let db = db else { return }

        let all = db.markers_all ?? []
        let typeColors = db.marker_types ?? [:]
        let coreTypes: Set<String> = ["waypoint", "region", "phone-booth", "tower"]

        categories = Self.categoryDefs.map { d in
            let count = all.filter { $0.type == d.id }.count

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
                isEnabled: coreTypes.contains(d.id),
                count: count
            )
        }
    }

    private func defaultColor(for type: String) -> Color {
        switch type {
        case "waypoint":     return Color(red: 0.92, green: 0.70, blue: 0.03)
        case "region":       return Color(red: 0.42, green: 0.45, blue: 0.50)
        case "phone-booth":  return Color(red: 0.02, green: 0.71, blue: 0.83)
        case "tower":        return Color(red: 0.96, green: 0.62, blue: 0.04)
        case "boss":         return Color(red: 0.94, green: 0.27, blue: 0.27)
        case "quest":        return Color(red: 0.23, green: 0.51, blue: 0.96)
        case "activity":     return Color(red: 0.93, green: 0.28, blue: 0.60)
        case "viewpoint":    return Color(red: 0.02, green: 0.72, blue: 0.83)
        case "service":      return Color(red: 0.08, green: 0.72, blue: 0.55)
        case "shop":         return Color(red: 0.02, green: 0.71, blue: 0.83)
        case "oracle-stone": return Color(red: 0.65, green: 0.55, blue: 0.98)
        case "chest":        return Color(red: 0.96, green: 0.62, blue: 0.04)
        case "collectible":  return Color(red: 0.13, green: 0.77, blue: 0.37)
        case "mystery-box":  return Color(red: 0.49, green: 0.23, blue: 0.93)
        case "gift-21":      return Color(red: 0.96, green: 0.45, blue: 0.71)
        case "currency":     return Color(red: 0.98, green: 0.80, blue: 0.08)
        case "arc-plate":    return Color(red: 0.55, green: 0.36, blue: 0.96)
        case "monster":      return Color(red: 0.86, green: 0.15, blue: 0.15)
        default:             return Theme.cyan
        }
    }
}

// MARK: - 地图入口按钮

struct GameMapCard: View {
    @State private var showMap = false

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
