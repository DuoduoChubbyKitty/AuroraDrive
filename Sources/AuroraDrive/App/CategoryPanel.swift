// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  CategoryPanel.swift — 地图窗口右栏「标签分类」面板
// ============================================================================
//
//  【这个面板解决什么】
//  地图上的标记有 42 类、归 7 个语义组。没有分类面板时，用户面对的是
//  「一片同色点」——看得见但看不懂，也没法只看自己关心的那一类。
//  面板把「有哪些类 / 每类多少个 / 现在开着哪些」摊开，一次点击切一类。
//
//  【数据源与容错（硬性约定）】
//  首选 `models/map_categories.json`（由数据层工具产出）；
//  文件缺失 / 解析失败 / 结构不符 ⇒ **自动回落到 `models/marker_taxonomy.json`**，
//  再不行 ⇒ 空面板 + 明确提示。**绝不崩、绝不空白**：
//  地图是主界面，右栏崩了整个窗口就废了。
//
//  【为什么解析写成「多形态兼容」】
//  `map_categories.json` 的最终结构由数据层任务确定，本文件先落地时它还不在。
//  故这里同时接受三种形态：
//    形态 A：groups[].categories[]  —— 分类嵌在组里
//    形态 B：groups[] + categories[]（分类带 group 字段）—— 与 marker_taxonomy.json 同构
//    形态 C：顶层直接是分类数组
//  这样无论数据层最后交的是哪一种，右栏都能出 7 组，不需要两边对表改代码。
//
//  【显隐状态存哪】
//  `UserDefaults` key `auroradrive.map.categories`（存**已启用**的分类 id 数组）。
//  首次运行（无持久化值）用数据里的 `defaultOn` 决定默认开启哪些。
//  折叠状态单独存 `auroradrive.map.categories.collapsed`（它不是业务数据，
//  不该和显隐混在一个键里 —— 混在一起以后想改任一语义都要做迁移）。
// ============================================================================

import SwiftUI
import AppKit
import Foundation

// ============================================================================
// MARK: - 数据模型
// ============================================================================

/// 一个分类（= 地图上可独立开关的一类标记）。
struct MapCategoryItem: Identifiable, Hashable {
    /// 分类 id（数据层口径，如 `oracle-stone`）
    let id: String
    /// 显示名（如「谕石」）
    let label: String
    /// 所属组 id
    let groupID: String
    /// 分类色（hex 字符串，如 "4CC9FF"）
    let colorHex: String
    /// ⚠️ 数据里的 `icon` 是**游戏图标名**（如 `YH_UI_mapicon_yushi_1`），
    /// **不是 SF Symbol** —— 直接喂给 `Image(systemName:)` 会渲染成空白。
    /// 真图标走 `iconFile`（`models/map_icons/` 下的文件名），这个字段仅留档。
    let icon: String?
    /// 真图标文件名（`models/map_icons/<iconFile>`），由 `map_icon_map.json` 映射而来。
    /// `nil` = 该分类没有可用图标 → 调用方用 `symbolName` 兜底。
    let iconFile: String?
    /// 该类标记总数
    let count: Int
    /// 组内排序
    let order: Int

    /// 分类色。非法 hex 回落冰蓝 —— 不崩、不黑。
    var color: Color { Aurora.colorFromHex(colorHex) }

    /// SF Symbol 兜底图标（按组给一个稳定语义图标）。
    var symbolName: String { MapCategoryCatalog.fallbackSymbol(forGroup: groupID) }
}

/// 一个语义组（可折叠）。
struct MapCategoryGroup: Identifiable, Hashable {
    let id: String
    let label: String
    let order: Int
    let colorHex: String
    /// 首次运行时的默认开关（无持久化值时生效）
    let defaultOn: Bool
    let categories: [MapCategoryItem]
    /// 空组原因（数据层给的 `emptyReason`）。
    ///
    /// 为什么保留空组而不是隐藏：本数据集只有 4 组有数据（商店/服务/地标为空，
    /// 上游 `map-data.json` 那 42 类里就没有）。**隐藏**会让用户以为"没有这个功能"，
    /// **显示并说明原因**才是诚实的 —— 也让「7 组齐全」这条契约可被断言。
    var emptyReason: String? = nil

    var color: Color { Aurora.colorFromHex(colorHex) }
    var totalCount: Int { categories.reduce(0) { $0 + $1.count } }
    var isEmpty: Bool { categories.isEmpty }
}

/// 三态（全选 / 半选 / 未选）—— 组头复选框用。
enum MapCategoryTriState {
    case none, partial, all
}

// ============================================================================
// MARK: - 数据源（多形态容错解析）
// ============================================================================

enum MapCategoryCatalog {

    /// 加载结果（带出处与提示，供自检断言「数据到底从哪来的」）。
    struct LoadResult {
        var groups: [MapCategoryGroup]
        /// 实际生效的数据源（绝对路径或「内置空」）
        var sourcePath: String
        /// 人类可读的加载说明（含回落原因）
        var note: String
        /// 真图标目录（`models/map_icons`）；未解析到时为 nil
        var iconDir: URL?
    }

    /// 组 id → 回退 SF Symbol。
    ///
    /// 为什么需要：词表/分类数据里 `icon` 字段目前是 `null`，
    /// 面板若直接显示 `Image(systemName: "")` 会得到空白甚至占位符。
    /// 按组给一个稳定的语义图标，保证「7 组齐全」在视觉上立刻可辨。
    static func fallbackSymbol(forGroup gid: String) -> String {
        switch gid {
        case "explore":  return "sparkles"
        case "resource": return "cube.fill"
        case "travel":   return "airplane"
        case "monster":  return "pawprint.fill"
        case "shop":     return "cart.fill"
        case "service":  return "wrench.and.screwdriver.fill"
        case "landmark": return "mappin.and.ellipse"
        default:         return "circle.fill"
        }
    }

    /// 候选数据源（按优先级）。
    static func candidateURLs() -> [URL] {
        let root = AuroraPaths.projectRoot()
        return [
            root.appendingPathComponent("models/map_categories.json"),
            AuroraPaths.modelsDir().appendingPathComponent("map_categories.json"),
            root.appendingPathComponent("models/marker_taxonomy.json"),
            AuroraPaths.modelsDir().appendingPathComponent("marker_taxonomy.json"),
        ]
    }

    /// 同步加载（自检 / 离屏截图夹具用）。
    static func load() -> LoadResult {
        let icons = loadIconMap()
        var tried: [String] = []
        for url in candidateURLs() {
            let path = url.path
            // 同一份文件可能被两个候选路径命中，去重
            if tried.contains(path) { continue }
            tried.append(path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let data = FileManager.default.contents(atPath: path) else {
                continue
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            if let groups = parse(root: obj, iconMap: icons.map), !groups.isEmpty {
                let name = url.lastPathComponent
                return LoadResult(groups: groups, sourcePath: path,
                                  note: "已加载 \(name)：\(groups.count) 组 / "
                                      + "\(groups.reduce(0) { $0 + $1.categories.count }) 类"
                                      + "（图标 \(icons.map.count) 个）",
                                  iconDir: icons.dir)
            }
        }
        return LoadResult(groups: [], sourcePath: "（无）",
                          note: "未找到可用的分类数据（尝试过 \(tried.count) 个路径）",
                          iconDir: icons.dir)
    }

    /// 读 `models/map_icon_map.json`：分类 id → `models/map_icons/` 下的文件名。
    ///
    /// 缺失不致命：拿不到就全部走 `symbolName` 兜底，面板照常可用。
    static func loadIconMap() -> (map: [String: String], dir: URL?) {
        let root = AuroraPaths.projectRoot()
        let jsonCands = [
            root.appendingPathComponent("models/map_icon_map.json"),
            AuroraPaths.modelsDir().appendingPathComponent("map_icon_map.json"),
        ]
        for url in jsonCands {
            guard let data = FileManager.default.contents(atPath: url.path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let map = obj["map"] as? [String: String] else { continue }
            // 目录优先用 json 自报的（相对项目根），否则回落默认位置
            var dir = root.appendingPathComponent("models/map_icons")
            if let d = obj["iconDir"] as? String, !d.isEmpty {
                let cand = root.appendingPathComponent(d)
                if FileManager.default.fileExists(atPath: cand.path) { dir = cand }
            }
            return (map, dir)
        }
        return ([:], nil)
    }

    // MARK: 解析

    /// 多形态解析：A（嵌套）/ B（扁平 + group 字段）/ C（顶层数组）。
    /// `iconMap`：分类 id → 图标文件名（可空，空则全部走 SF Symbol 兜底）。
    static func parse(root: Any, iconMap: [String: String] = [:]) -> [MapCategoryGroup]? {
        // ── 形态 C：顶层就是分类数组 ──
        if let arr = root as? [[String: Any]] {
            let items = arr.enumerated().compactMap {
                item(from: $1, groupID: nil, fallbackOrder: $0, iconMap: iconMap)
            }
            return assemble(groups: items, meta: [:])
        }

        guard let dict = root as? [String: Any] else { return nil }
        let rawGroups = dict["groups"] as? [[String: Any]] ?? []
        let rawCats = dict["categories"] as? [[String: Any]] ?? []

        // 组元信息（label / order / color / defaultOn / emptyReason）
        var meta: [String: GroupMeta] = [:]
        for g in rawGroups {
            guard let id = g["id"] as? String else { continue }
            meta[id] = GroupMeta(
                label: (g["label"] as? String) ?? id,
                order: intValue(g["order"]) ?? 99,
                colorHex: (g["color"] as? String) ?? "4CC9FF",
                defaultOn: boolValue(g["defaultOn"]) ?? false,
                emptyReason: g["emptyReason"] as? String)
        }

        // ── 形态 A：分类嵌在组里 ──
        var nested: [MapCategoryItem] = []
        var nestedHit = false
        for g in rawGroups {
            guard let gid = g["id"] as? String else { continue }
            guard let inner = g["categories"] as? [[String: Any]], !inner.isEmpty else { continue }
            nestedHit = true
            for (i, c) in inner.enumerated() {
                if let it = item(from: c, groupID: gid, fallbackOrder: i, iconMap: iconMap) {
                    nested.append(it)
                }
            }
        }
        if nestedHit {
            return assemble(groups: nested, meta: meta)
        }

        // ── 形态 B：顶层 categories + group 字段 ──
        if !rawCats.isEmpty {
            let items = rawCats.enumerated().compactMap {
                item(from: $1, groupID: $1["group"] as? String,
                     fallbackOrder: $0, iconMap: iconMap)
            }
            if !items.isEmpty { return assemble(groups: items, meta: meta) }
        }

        return nil
    }

    private struct GroupMeta {
        let label: String
        let order: Int
        let colorHex: String
        let defaultOn: Bool
        let emptyReason: String?
    }

    /// 单个分类条目 → 模型。缺 id 或缺 label 的条目直接丢弃（宁可少一类，不要空行）。
    private static func item(from d: [String: Any], groupID: String?,
                             fallbackOrder: Int,
                             iconMap: [String: String]) -> MapCategoryItem? {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        let label = (d["label"] as? String) ?? id
        // groupID 优先取参数（形态 A 由外层组给），其次取条目自带（形态 B）
        let gid = groupID ?? (d["group"] as? String) ?? ""
        return MapCategoryItem(
            id: id,
            label: label,
            groupID: gid,
            colorHex: (d["color"] as? String) ?? "4CC9FF",
            icon: d["icon"] as? String,
            // 真图标走 icon_map（数据里的 icon 是游戏图标名，不能当 SF Symbol 用）
            iconFile: iconMap[id],
            count: intValue(d["count"]) ?? 0,
            order: intValue(d["order"]) ?? fallbackOrder)
    }

    /// 把扁平分类列表装配成「组 → 分类」，按 order 稳定排序。
    private static func assemble(groups items: [MapCategoryItem],
                                 meta: [String: GroupMeta]) -> [MapCategoryGroup]? {
        guard !items.isEmpty else { return nil }
        var byGroup: [String: [MapCategoryItem]] = [:]
        for it in items { byGroup[it.groupID, default: []].append(it) }

        var out: [MapCategoryGroup] = []
        for (gid, cats) in byGroup {
            let m = meta[gid]
            out.append(MapCategoryGroup(
                id: gid,
                label: m?.label ?? (gid.isEmpty ? "未分组" : gid),
                order: m?.order ?? 99,
                colorHex: m?.colorHex ?? cats.first?.colorHex ?? "4CC9FF",
                defaultOn: m?.defaultOn ?? false,
                categories: cats.sorted {
                    $0.order != $1.order ? $0.order < $1.order : $0.label < $1.label
                },
                emptyReason: m?.emptyReason))
        }
        // ── 补齐「有元信息但一个分类都没有」的空组 ──
        // 数据层会显式给出空组（带 emptyReason），例如本数据集的商店/服务/地标。
        // 若只按 categories 反推，这 3 组会整组消失 → 面板只剩 4 组，
        // 用户以为"没有这个功能"。故这里按 meta 补齐，保证「7 组齐全」。
        for (gid, m) in meta where byGroup[gid] == nil {
            out.append(MapCategoryGroup(
                id: gid, label: m.label, order: m.order, colorHex: m.colorHex,
                defaultOn: m.defaultOn, categories: [], emptyReason: m.emptyReason))
        }
        // 组间排序：order 优先，其次 label（保证同输入同输出，截图可 A/B）
        out.sort { $0.order != $1.order ? $0.order < $1.order : $0.label < $1.label }
        return out
    }

    // JSONSerialization 的数字可能是 NSNumber / Int / Double，统一取值
    private static func intValue(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    private static func boolValue(_ v: Any?) -> Bool? {
        if let n = v as? NSNumber { return n.boolValue }
        if let b = v as? Bool { return b }
        return nil
    }
}

// ============================================================================
// MARK: - 真图标缓存（models/map_icons/*.webp）
// ============================================================================

/// 分类真图标（`models/map_icons/` 下的 webp）的懒加载缓存。
///
/// 【为什么要缓存】面板每帧求值都会读图标；不缓存就是每帧几十次磁盘 IO。
/// 【为什么含负缓存】文件缺失要记住「缺」这件事，否则每帧都重试一次失败的读盘
///   （42 个分类里有 4 个是 `group-fallback`，天然没有图标文件）。
/// 【为什么不做成 @Observable】图标是**只读资源**，加载完就永不变；
///   让它参与观察只会在首次加载时多触发一次无意义的视图失效。
///   首帧缺图时行内会画 SF Symbol 兜底，观感不闪。
@MainActor
final class MapIconStore {
    static let shared = MapIconStore()

    /// 文件名 → NSImage（`nil` = 已确认缺失/解码失败，负缓存）
    private var cache: [String: NSImage?] = [:]
    private var dir: URL?

    private init() {}

    func configure(dir: URL?) { self.dir = dir }

    /// 取图标。首次访问读盘并缓存（含失败结果）。
    func image(_ file: String?) -> NSImage? {
        guard let file, !file.isEmpty else { return nil }
        if let hit = cache[file] { return hit }          // 含负缓存命中
        guard let dir else { cache[file] = nil; return nil }
        let url = dir.appendingPathComponent(file)
        let img = NSImage(contentsOf: url)
        cache[file] = img
        return img
    }

    /// 后台预热（面板出现后调用，避免首帧逐行读盘）。
    ///
    /// 只预读**当前分类用得到的**文件，不扫整个目录 —— 目录里有 150 个文件，
    /// 而面板只显示 42 个。
    func warm(_ files: [String]) {
        let dir = self.dir
        let pending = files.filter { cache[$0] == nil }
        guard let dir, !pending.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            var loaded: [String: NSImage?] = [:]
            for f in pending {
                loaded[f] = NSImage(contentsOf: dir.appendingPathComponent(f))
            }
            DispatchQueue.main.async {
                for (k, v) in loaded where self.cache[k] == nil { self.cache[k] = v }
            }
        }
    }

    /// 诊断：已缓存的正/负条目数
    var debugCounts: (loaded: Int, missing: Int) {
        (cache.values.filter { $0 != nil }.count, cache.values.filter { $0 == nil }.count)
    }
}

// ============================================================================
// MARK: - 显隐状态（跨视图共享 + UserDefaults 持久化）
// ============================================================================

/// 分类显隐的唯一真相源。
///
/// 做成 `@Observable` 单例而不是 `CategoryPanel` 的 `@State`，理由有二：
///   ① 显隐是**业务状态**，不该随面板视图的创建/销毁而丢；
///   ② 将来把筛选接到地图渲染时，地图侧只需读同一个实例，不必层层传 Binding。
@MainActor
@Observable
final class MapCategorySelection {

    static let shared = MapCategorySelection()

    /// 显隐持久化键（任务契约，不要改）
    static let defaultsKey = "auroradrive.map.categories"
    /// 折叠状态持久化键
    static let collapsedKey = "auroradrive.map.categories.collapsed"

    private(set) var groups: [MapCategoryGroup] = []
    /// 已启用（显示中）的分类 id
    private(set) var enabled: Set<String> = []
    /// 已折叠的组 id
    private(set) var collapsed: Set<String> = []
    /// 数据出处说明（自检断言用）
    private(set) var sourceLabel: String = "（未加载）"
    private(set) var isReady = false

    private var didStart = false

    private init() {}

    // MARK: 加载

    /// 幂等异步加载（UI 走这条，不阻塞首帧）。
    func ensureLoaded() {
        if didStart { return }
        didStart = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = MapCategoryCatalog.load()
            DispatchQueue.main.async { self.apply(r) }
        }
    }

    /// 同步加载（自检 / 离屏夹具专用：那两条路径没有「稍后再刷新」的机会）。
    func ensureLoadedSync() {
        if isReady { return }
        didStart = true
        apply(MapCategoryCatalog.load())
    }

    private func apply(_ r: MapCategoryCatalog.LoadResult) {
        groups = r.groups
        sourceLabel = r.note
        MapIconStore.shared.configure(dir: r.iconDir)
        restoreOrDefault()
        isReady = true
        // 图标后台预热：面板首帧用 SF Symbol 兜底，读盘完成后自动换真图标。
        // 不预热的话，展开 7 组时会在主线程上串行读 42 次盘（实测每个 ~0.3ms，
        // 合计 ~13ms 的卡顿 —— 不至于崩，但展开动画会明显掉帧）。
        MapIconStore.shared.warm(groups.flatMap { $0.categories.compactMap(\.iconFile) })
    }

    /// 读持久化值；没有就用数据里的 `defaultOn`。
    ///
    /// 注意两件事：
    ///   · 持久化值里可能残留**已不存在的分类 id**（数据换版），必须与当前词表求交，
    ///     否则 `enabled` 会永远大于真实分类数，计数对不上；
    ///   · 「持久化了空数组」与「从没存过」是两种语义（用户清空 vs 首次运行），
    ///     `UserDefaults.array` 返回 `[]` 而非 `nil`，正好能区分。
    private func restoreOrDefault() {
        let d = UserDefaults.standard
        let known = Set(groups.flatMap { $0.categories.map(\.id) })

        if let saved = d.array(forKey: Self.defaultsKey) as? [String] {
            enabled = Set(saved).intersection(known)
        } else {
            var def: Set<String> = []
            for g in groups where g.defaultOn {
                for c in g.categories { def.insert(c.id) }
            }
            enabled = def
        }

        if let col = d.array(forKey: Self.collapsedKey) as? [String] {
            collapsed = Set(col).intersection(Set(groups.map(\.id)))
        }

        // 首次运行（键不存在）也要落一次盘：
        //   ① 让「默认值」成为**显式**状态，下次改数据不会静默改变用户的既有选择；
        //   ② 自检要能断言「键存在」，否则首次运行时那条断言会假失败。
        persist()
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(enabled.sorted(), forKey: Self.defaultsKey)
        d.set(collapsed.sorted(), forKey: Self.collapsedKey)
    }

    // MARK: 查询

    var totalCategories: Int { groups.reduce(0) { $0 + $1.categories.count } }
    var totalCount: Int { groups.reduce(0) { $0 + $1.totalCount } }
    var enabledCategories: Int { enabled.count }
    var visibleCount: Int {
        groups.reduce(0) { acc, g in
            acc + g.categories.reduce(0) { $0 + (enabled.contains($1.id) ? $1.count : 0) }
        }
    }

    func isOn(_ id: String) -> Bool { enabled.contains(id) }
    func isCollapsed(_ id: String) -> Bool { collapsed.contains(id) }

    func onCount(_ g: MapCategoryGroup) -> Int {
        g.categories.reduce(0) { $0 + (enabled.contains($1.id) ? 1 : 0) }
    }

    func triState(_ g: MapCategoryGroup) -> MapCategoryTriState {
        let on = onCount(g)
        if on == 0 { return .none }
        if on == g.categories.count { return .all }
        return .partial
    }

    // MARK: 变更

    func toggle(_ id: String) {
        if enabled.contains(id) { enabled.remove(id) } else { enabled.insert(id) }
        persist()
    }

    func setGroup(_ g: MapCategoryGroup, on: Bool) {
        for c in g.categories {
            if on { enabled.insert(c.id) } else { enabled.remove(c.id) }
        }
        persist()
    }

    func toggleCollapsed(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        persist()
    }

    func selectAll() {
        enabled = Set(groups.flatMap { $0.categories.map(\.id) })
        persist()
    }

    func clearAll() {
        enabled = []
        persist()
    }

    /// 自检用：把状态恢复到「数据默认值」（不影响磁盘）。
    func resetToDefaults() {
        var def: Set<String> = []
        for g in groups where g.defaultOn {
            for c in g.categories { def.insert(c.id) }
        }
        enabled = def
    }
}

// ============================================================================
// MARK: - 主题色扩展
// ============================================================================

extension Aurora {
    /// hex 字符串 → Color。非法输入回落冰蓝（与 `MarkerTaxonomy.Group.parseHex` 同口径）。
    static func colorFromHex(_ s: String) -> Color {
        let t = s.hasPrefix("#") ? String(s.dropFirst()) : s
        return Color(hex: UInt32(t, radix: 16) ?? 0x4CC9FF)
    }
}

// ============================================================================
// MARK: - 三态复选框
// ============================================================================

/// 组头三态复选框：全选 ✓ / 半选 − / 未选 空。
struct MapCategoryTriBox: View {
    let state: MapCategoryTriState
    var size: CGFloat = 12

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Aurora.radiusBadge, style: .continuous)
                .fill(state == .none ? Color.white.opacity(0.05) : Aurora.ice.opacity(0.22))
            RoundedRectangle(cornerRadius: Aurora.radiusBadge, style: .continuous)
                .strokeBorder(state == .none ? Aurora.hair3 : Aurora.ice.opacity(0.65),
                              lineWidth: 1)
            switch state {
            case .all:
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.58, weight: .bold))
                    .foregroundStyle(Aurora.iceHi)
            case .partial:
                Capsule()
                    .fill(Aurora.iceHi)
                    .frame(width: size * 0.5, height: 1.6)
            case .none:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
    }
}

// ============================================================================
// MARK: - 面板
// ============================================================================

/// 地图窗口右栏：标签分类面板。
///
/// `state` 用于和地图侧交叉核对标记总数（面板计数与地图计数不一致时肉眼可见），
/// `searchText` 由窗口顶部搜索框传入，用于过滤分类行。
struct CategoryPanel: View {
    @Bindable var state: DriveState
    var searchText: String = ""

    @State private var sel = MapCategorySelection.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Aurora.hair1).frame(height: 1)
            content
            Rectangle().fill(Aurora.hair1).frame(height: 1)
            footer
        }
        .background(Aurora.s1)
        .overlay(alignment: .leading) {
            Rectangle().fill(Aurora.hair2).frame(width: 1)
        }
        .onAppear { sel.ensureLoaded() }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: Aurora.sp1) {
            HStack(spacing: Aurora.sp2) {
                Text("标签分类")
                    .font(.system(size: Aurora.fsSmall, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Aurora.t1)
                Text("\(sel.groups.count) 组")
                    .font(.system(size: Aurora.fsMicro))
                    .foregroundStyle(Aurora.ice)
                    .auroraMetric("\(sel.groups.count)")
                    .padding(.horizontal, Aurora.sp1).padding(.vertical, Aurora.sp1)
                    .background(Capsule().fill(Aurora.iceWash))
                    .overlay(Capsule().strokeBorder(Aurora.iceLo, lineWidth: 1))
                Spacer()
                Text("\(sel.enabledCategories)/\(sel.totalCategories)")
                    .font(.system(size: Aurora.fsMicro, design: .monospaced))
                    .foregroundStyle(Aurora.t3)
                    .auroraMetric("\(sel.enabledCategories)/\(sel.totalCategories)")
            }
            Text(sel.isReady ? sel.sourceLabel : "加载中…")
                .font(.system(size: Aurora.fsMicro))
                .foregroundStyle(Aurora.t3)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Aurora.sp3)
        .padding(.vertical, Aurora.sp3)
    }

    // MARK: 列表

    @ViewBuilder
    private var content: some View {
        if !sel.isReady {
            VStack {
                Spacer()
                Text("加载中…").font(.system(size: Aurora.fsMicro)).foregroundStyle(Aurora.t3)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if sel.groups.isEmpty {
            VStack(spacing: Aurora.sp2) {
                Spacer()
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: Aurora.fsH1))
                    .foregroundStyle(Aurora.t4)
                Text("无分类数据").font(.system(size: Aurora.fsMicro)).foregroundStyle(Aurora.t3)
                Text("models/map_categories.json\n或 models/marker_taxonomy.json")
                    .font(.system(size: Aurora.fsMicro))
                    .foregroundStyle(Aurora.t3)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleGroups) { g in
                        groupSection(g)
                    }
                }
                .padding(.vertical, Aurora.sp2)
            }
        }
    }

    /// 搜索时只保留命中的分类；整组都没命中就把组也藏掉。
    private var visibleGroups: [MapCategoryGroup] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sel.groups }
        return sel.groups.compactMap { g in
            let hit = g.categories.filter {
                $0.label.lowercased().contains(q) || $0.id.lowercased().contains(q)
            }
            guard !hit.isEmpty else { return nil }
            return MapCategoryGroup(id: g.id, label: g.label, order: g.order,
                                    colorHex: g.colorHex, defaultOn: g.defaultOn,
                                    categories: hit, emptyReason: g.emptyReason)
        }
    }

    @ViewBuilder
    private func groupSection(_ g: MapCategoryGroup) -> some View {
        let tri = sel.triState(g)
        let folded = sel.isCollapsed(g.id)
        let empty = g.isEmpty

        VStack(spacing: 0) {
            // ── 组头：折叠箭头 + 三态框 + 组名 + 已选/总数 ──
            HStack(spacing: Aurora.sp2) {
                Button { sel.toggleCollapsed(g.id) } label: {
                    Text(folded ? "▸" : "▾")
                        .font(.system(size: Aurora.fsMicro))
                        .foregroundStyle(Aurora.t3)
                        .frame(width: 10)
                }
                .buttonStyle(AuroraButtonStyle())

                Button { sel.setGroup(g, on: tri != .all) } label: {
                    MapCategoryTriBox(state: tri)
                }
                .buttonStyle(AuroraButtonStyle())
                .disabled(empty)
                .help(empty ? "本组无数据" : (tri == .all ? "取消全选本组" : "全选本组"))

                Circle()
                    .fill(empty ? Aurora.t4 : g.color)
                    .frame(width: 5, height: 5)

                Text(g.label)
                    .font(.system(size: Aurora.fsSmall, weight: .medium))
                    .foregroundStyle(empty ? Aurora.t3 : Aurora.t2)

                Spacer(minLength: 4)

                if empty {
                    Text("无数据")
                        .font(.system(size: Aurora.fsMicro))
                        .foregroundStyle(Aurora.t3)
                } else {
                    Text("\(sel.onCount(g))/\(g.categories.count)")
                        .font(.system(size: Aurora.fsMicro, design: .monospaced))
                        .foregroundStyle(tri == .none ? Aurora.t3 : Aurora.ice)
                        .auroraMetric("\(sel.onCount(g))/\(g.categories.count)")
                }
            }
            .padding(.horizontal, Aurora.sp3)
            .padding(.vertical, Aurora.sp2)
            .contentShape(Rectangle())
            .onTapGesture { sel.toggleCollapsed(g.id) }

            if !folded {
                if empty {
                    // 空组：**显示原因**而不是静默消失。
                    // 本数据集只有 4 组有数据，另 3 组是上游数据本身就没有这类，
                    // 写清楚才不会让人以为是 App 漏了功能。
                    Text(g.emptyReason ?? "本数据集无此类标记")
                        .font(.system(size: Aurora.fsMicro))
                        .foregroundStyle(Aurora.t3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, Aurora.sp6)
                        .padding(.trailing, Aurora.sp3)
                        .padding(.bottom, Aurora.sp2)
                } else {
                    ForEach(g.categories) { c in
                        categoryRow(c, group: g)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func categoryRow(_ c: MapCategoryItem, group g: MapCategoryGroup) -> some View {
        let on = sel.isOn(c.id)
        Button { sel.toggle(c.id) } label: {
            HStack(spacing: Aurora.sp2) {
                MapCategoryTriBox(state: on ? .all : .none, size: 11)
                // 真图标优先（models/map_icons/*.webp）；缺失时 SF Symbol 兜底。
                // 两条路都保证「图标位永远有东西」，不会出现空白方块。
                if let img = MapIconStore.shared.image(c.iconFile) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                        .opacity(on ? 1.0 : 0.35)
                } else {
                    Image(systemName: c.symbolName)
                        .font(.system(size: Aurora.fsMicro))
                        .foregroundStyle(on ? c.color : Aurora.t3)
                        .frame(width: 14)
                }
                Text(c.label)
                    .font(.system(size: Aurora.fsMicro))
                    .foregroundStyle(on ? Aurora.t1 : Aurora.t3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(c.count)")
                    .font(.system(size: Aurora.fsMicro, design: .monospaced))
                    .foregroundStyle(on ? Aurora.t2 : Aurora.t3)
                    .auroraMetric("\(c.count)")
            }
            .padding(.leading, Aurora.sp6)
            .padding(.trailing, Aurora.sp3)
            .padding(.vertical, Aurora.sp1)
            .background(on ? c.color.opacity(0.07) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(AuroraButtonStyle())
        .help("\(c.label) · \(c.count) 个")
    }

    // MARK: 底部

    private var footer: some View {
        VStack(spacing: Aurora.sp2) {
            HStack(spacing: Aurora.sp2) {
                footerButton("全选") { sel.selectAll() }
                footerButton("清空") { sel.clearAll() }
            }
            HStack(spacing: Aurora.sp1) {
                Text("\(sel.visibleCount)")
                    .font(.system(size: Aurora.fsMicro, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Aurora.iceHi)
                    .auroraMetric("\(sel.visibleCount)")
                Text("个标记显示中")
                    .font(.system(size: Aurora.fsMicro))
                    .foregroundStyle(Aurora.t3)
                Spacer(minLength: 4)
                // 与地图侧交叉核对：不一致说明分类数据与地图数据不是同一版。
                // 只在 >0 时显示 —— 独立开地图窗口时标记库可能还没加载完，
                // 显示「地图 0」会让人误以为地图没数据（假信息比没信息更糟）。
                if state.mapMarkerCount > 0 {
                    Text("地图 \(state.mapMarkerCount)")
                        .font(.system(size: Aurora.fsMicro, design: .monospaced))
                        .foregroundStyle(Aurora.t3)
                }
            }
        }
        .padding(.horizontal, Aurora.sp3)
        .padding(.vertical, Aurora.sp2)
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Aurora.fsMicro, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Aurora.sp1)
                .background(RoundedRectangle(cornerRadius: Aurora.r1, style: .continuous)
                    .fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: Aurora.r1, style: .continuous)
                    .strokeBorder(Aurora.hair2, lineWidth: 1))
                .foregroundStyle(Aurora.t2)
        }
        .buttonStyle(AuroraButtonStyle())
    }
}
