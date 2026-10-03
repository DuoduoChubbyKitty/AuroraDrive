// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  MarkerTaxonomy.swift — 标记分类词表（7 组）
// ============================================================================
//
//  数据来源：models/marker_taxonomy.json
//    由 tools/roadnet/build_taxonomy.py 从 FINAL_complete_map_database.json 生成。
//    原始 7.2 MB 主库**始终只读**，词表是独立文件 —— 这样重跑词表不会碰数据。
//
//  ── 为什么需要它 ──────────────────────────────────────────────────────────
//  App 原来只认 3 个 `type`，数据源有 42 类，实测匹配率 6.6%（376/5677）。
//  结果是整张地图一片同色点，看不出类别；而唯一显示名字的 `waypoint`
//  里 80/100 叫「计程车站」→ 满屏那三个字。词表把 5677 个标记归入 7 个
//  语义组，实现「按类别着色 + 按组筛选 + 按组聚类」。
//
//  ── 容错约定（硬性）──────────────────────────────────────────────────────
//  词表文件缺失 / 解析失败 / 结构不对 ⇒ `shared == nil`，
//  调用方**必须**回落到旧的 `kind` 配色逻辑，**绝不崩、绝不空白**。
//  这不是"优雅降级"的客套话：地图是主界面，崩了等于整个 App 不能用。

import Foundation
import SwiftUI

/// 标记分类词表。
enum MarkerTaxonomy {

    /// 一个语义组
    struct Group: Identifiable, Hashable {
        let id: String          // explore / resource / travel / ...
        let label: String       // 「探索度」等
        let order: Int
        let defaultOn: Bool
        /// 组色（hex 字符串，如 "4CC9FF"）
        let colorHex: String

        var color: Color { Color(hex: Self.parseHex(colorHex)) }
        var colorUIKit: UInt32 { Self.parseHex(colorHex) }

        /// "4CC9FF" → 0x4CC9FF。非法输入回落冰蓝（不崩、不黑）
        static func parseHex(_ s: String) -> UInt32 {
            let t = s.hasPrefix("#") ? String(s.dropFirst()) : s
            return UInt32(t, radix: 16) ?? 0x4CC9FF
        }
    }

    /// 已加载的词表
    private(set) static var groups: [Group] = []
    /// marker.id → group.id
    private(set) static var groupByMarker: [String: String] = [:]
    /// group.id → 该组成员数
    private(set) static var countByGroup: [String: Int] = [:]
    /// 词表是否已就绪（UI 据此重新求值）
    private(set) static var loaded = false
    /// 最近一次加载失败原因（如实显示，不编造）
    private(set) static var loadError: String?

    private static var isLoading = false
    private static var didLoad = false

    /// 词表文件路径。`AURORA_MARKER_TAXONOMY` 可覆写（便于 A/B）。
    static var url: URL {
        if let p = ProcessInfo.processInfo.environment["AURORA_MARKER_TAXONOMY"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return AuroraPaths.modelsDir().appendingPathComponent("marker_taxonomy.json")
    }

    /// 默认开启的组（`AURORA_MAP_DEFAULT_GROUPS` 可覆写，逗号分隔中文名或 id）
    /// 默认开启的组（返回**中文名**集合，与筛选条 state 同一口径）。
    ///
    /// `AURORA_MAP_DEFAULT_GROUPS` 接受**中文名或组 id**，逗号分隔。
    /// 两种都支持是必要的：文档/脚本里写 `travel` 更省事（不受中文改动影响），
    /// 而 UI 里存的是中文名。若不在这里把 id 翻译成中文名，
    /// 传 `travel` 就会得到空集 → 地图上一个标记都不显示。
    ///
    /// 实测踩过：初版直接 `Set(拆分的字符串)` 透传，传 `travel` 时
    /// 过滤后 0 个标记（因为标记的 `groupLabel` 是「传送点」，
    /// 永远匹配不上 `travel`）。这种错很隐蔽 —— 不崩、不报错，
    /// 只是地图空了。
    static var defaultOnGroups: Set<String> {
        if let s = ProcessInfo.processInfo.environment["AURORA_MAP_DEFAULT_GROUPS"], !s.isEmpty {
            let parsed = parseDefaultGroups(s)
            if !parsed.isEmpty { return parsed }
        }
        return Set(groups.filter { $0.defaultOn }.map { $0.label })
    }

    /// 把 `AURORA_MAP_DEFAULT_GROUPS` 的原始字符串解析成中文名集合。
    ///
    /// 抽成纯函数（不读环境）是为了**可测**：`--taxonomy-selftest` 直接喂
    /// 各种输入验证，不用改环境变量重开进程。
    ///
    /// 接受中文名或组 id，逗号分隔，可混写。两者都不匹配的 token 被忽略
    /// （环境变量写错不该让地图空白）。
    static func parseDefaultGroups(_ raw: String) -> Set<String> {
        var out: Set<String> = []
        for part in raw.split(separator: ",") {
            let tok = part.trimmingCharacters(in: .whitespaces)
            if tok.isEmpty { continue }
            if groups.contains(where: { $0.label == tok }) {
                out.insert(tok)
            } else if let g = groups.first(where: { $0.id == tok }) {
                // id → 中文名（标记的 groupLabel 是中文名，不翻译就永远匹配不上）
                out.insert(g.label)
            }
        }
        return out
    }

    // MARK: 查询

    /// 取某标记的组（词表未加载或该标记无记录时 nil）
    static func group(forMarker id: String) -> Group? {
        guard let gid = groupByMarker[id] else { return nil }
        return groups.first { $0.id == gid }
    }

    /// 取某标记的组 id
    static func groupID(forMarker id: String) -> String? { groupByMarker[id] }

    // MARK: 加载

    /// 幂等异步加载（真机 UI 走这条）
    static func ensureLoaded() {
        if didLoad || isLoading { return }
        isLoading = true
        DispatchQueue.global(qos: .utility).async {
            let r = loadFromDisk()
            DispatchQueue.main.async {
                apply(r)
                isLoading = false
                didLoad = true
            }
        }
    }

    /// 同步加载（**仅离屏夹具**用，理由同 `MapDatabase.ensureLoadedSyncLegacy`）
    static func ensureLoadedSync() {
        guard !didLoad else { return }
        apply(loadFromDisk())
        didLoad = true
    }

    private static func apply(_ r: Result<([Group], [String: String], [String: Int]), TaxonomyFailure>) {
        switch r {
        case .success(let (g, map, cnt)):
            groups = g
            groupByMarker = map
            countByGroup = cnt
            loaded = true
            loadError = nil
            let summary = g.map { "\($0.label)=\(cnt[$0.id] ?? 0)" }.joined(separator: " ")
            print("[TAXONOMY] 已加载 \(g.count) 组 / \(map.count) 标记映射  \(summary)")
        case .failure(let why):
            // 关键：失败时保持 groups 为空 → 调用方回落旧配色。
            // 不抛错、不崩、不涂默认色假装成功。
            loadError = why.description
            groups = []
            groupByMarker = [:]
            countByGroup = [:]
            loaded = false
            print("[TAXONOMY] ✗ \(why) —— 地图将回落旧配色")
        }
    }

    /// 加载失败原因。
    /// `Result` 的 Failure 类型必须遵循 `Error` —— 裸用 `String` 编译不过。
    struct TaxonomyFailure: Error, CustomStringConvertible {
        let msg: String
        init(_ m: String) { msg = m }
        var description: String { msg }
    }

    private static func loadFromDisk()
    -> Result<([Group], [String: String], [String: Int]), TaxonomyFailure> {
        let u = url
        guard let data = FileManager.default.contents(atPath: u.path) else {
            return .failure(TaxonomyFailure("词表文件不存在：\(u.path)"))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(TaxonomyFailure("词表 JSON 解析失败：\(u.lastPathComponent)"))
        }
        guard let rawGroups = root["groups"] as? [[String: Any]],
              let rawBy = root["byMarker"] as? [String: Any] else {
            return .failure(TaxonomyFailure("词表结构非法：缺 groups / byMarker"))
        }

        var gs: [Group] = []
        for g in rawGroups {
            guard let id = g["id"] as? String,
                  let label = g["label"] as? String else { continue }
            gs.append(Group(id: id,
                            label: label,
                            order: (g["order"] as? NSNumber)?.intValue ?? 99,
                            defaultOn: (g["defaultOn"] as? NSNumber)?.boolValue ?? false,
                            colorHex: (g["color"] as? String) ?? "4CC9FF"))
        }
        guard !gs.isEmpty else { return .failure(TaxonomyFailure("词表 groups 为空")) }
        gs.sort { $0.order < $1.order }

        var map: [String: String] = [:]
        map.reserveCapacity(rawBy.count)
        var cnt: [String: Int] = [:]
        for (mid, v) in rawBy {
            guard let cat = v as? String else { continue }
            // category id 形如 "travel:type:waypoint" → 取组前缀
            let gid = String(cat.split(separator: ":").first ?? "")
            guard gs.contains(where: { $0.id == gid }) else { continue }
            map[mid] = gid
            cnt[gid, default: 0] += 1
        }
        guard !map.isEmpty else { return .failure(TaxonomyFailure("词表 byMarker 无有效条目")) }
        return .success((gs, map, cnt))
    }
}
