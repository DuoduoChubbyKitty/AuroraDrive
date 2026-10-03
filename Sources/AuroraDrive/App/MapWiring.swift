// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  MapWiring.swift — 小地图/大地图的真实坐标映射
// ============================================================================
//  真实数据链路：
//    CoordinateCapture 抓包 → 世界坐标(UE5厘米) → worldToMapPixel() 校准变换
//    → 地图像素(13056×13056) → 视口归一化坐标 → 小地图/大地图渲染
//
//  这些是**派生量**，一律现算，不落库、不缓存 —— 定位一变地图立刻跟着动。
//  定位未锁定时 mapPixelX/Y 返回地图中心，由调用方按 locatorFound 决定是否显示。

import SwiftUI
import CoreGraphics
import Foundation

@MainActor
extension DriveState {

    // MARK: - 世界坐标 → 地图像素（与 CoordinateCapture.worldToMapPixel 同一套校准常量）

    /// 世界坐标 X（UE5 厘米）→ 地图像素 X
    ///
    /// `nonisolated`：本函数是**纯数学**（只读全局校准常量，不碰任何
    /// `DriveState` 实例状态），而调用方可能不在主线程 —— 例如
    /// `--route-selftest` 这类一次性夹具，以及将来的后台预计算路径。
    /// 标 nonisolated 只放宽可调用范围，不改变行为。
    nonisolated static func worldToMapPixelX(_ wx: Double, _ wy: Double) -> Double {
        kCalibA * wx + kCalibB * wy + kCalibTX
    }

    /// 世界坐标 Y（UE5 厘米）→ 地图像素 Y
    nonisolated static func worldToMapPixelY(_ wx: Double, _ wy: Double) -> Double {
        kCalibA * wy - kCalibB * wx + kCalibTY
    }

    /// 自车所在的地图像素坐标（未锁定时给地图中心）
    var mapPixelX: Double {
        guard locatorFound else { return MapTileImage.mapPixels / 2 }
        return Self.worldToMapPixelX(locatorX, locatorY)
    }

    var mapPixelY: Double {
        guard locatorFound else { return MapTileImage.mapPixels / 2 }
        return Self.worldToMapPixelY(locatorX, locatorY)
    }

    // MARK: - 地图像素 → 世界坐标（上面两式的严格逆变换）

    /// 地图像素 X → 世界坐标 X（UE5 厘米）。
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// ⚠️ 为什么必须在这里自己推逆变换，而不是复用
    ///    `CoordinateTransform.invert`（NetworkLocator.swift:55）
    /// ══════════════════════════════════════════════════════════════════════
    ///
    /// 两处变换**不是同一个矩阵**：
    ///   · `MapWiring.worldToMapPixelX`：`mapX = A·wx + B·wy + TX`
    ///   · `CoordinateTransform.apply` ：`x'   = a·x  − b·y  + tx`
    ///   B 项**符号相反**（`+B` vs `−b`）。
    ///
    /// 数值上 B = 5.69e-08，对 1e5 量级的坐标只差 ~0.006 px，肉眼完全看不出
    /// —— 所以拿错逆变换**不会立刻暴露**，只会让点击设的目的地系统性偏一点点。
    /// 这正是"看不见的错"的典型：量小、恒定、永远不崩。
    /// 故此处从 MapWiring 自身的方程组严格求解，并配往返自检
    /// （`--route-selftest` 会断言偏差 < 0.5 px）。
    ///
    /// 【推导】
    ///   mapX = A·wx + B·wy + TX
    ///   mapY = A·wy − B·wx + TY
    ///   令 dx = mapX − TX, dy = mapY − TY：
    ///     [dx]   [ A   B ] [wx]
    ///     [dy] = [−B   A ] [wy]
    ///   行列式 det = A² + B²（A≠0，恒可逆）
    ///     wx = (A·dx − B·dy) / det
    ///     wy = (B·dx + A·dy) / det
    nonisolated static func mapPixelToWorldX(_ px: Double, _ py: Double) -> Double {
        let det = kCalibA * kCalibA + kCalibB * kCalibB
        guard det > 1e-12 else { return 0 }
        let dx = px - kCalibTX
        let dy = py - kCalibTY
        return (kCalibA * dx - kCalibB * dy) / det
    }

    /// 地图像素 Y → 世界坐标 Y（UE5 厘米）。推导见 `mapPixelToWorldX`。
    nonisolated static func mapPixelToWorldY(_ px: Double, _ py: Double) -> Double {
        let det = kCalibA * kCalibA + kCalibB * kCalibB
        guard det > 1e-12 else { return 0 }
        let dx = px - kCalibTX
        let dy = py - kCalibTY
        return (kCalibB * dx + kCalibA * dy) / det
    }

    /// 往返一致性误差（像素）。供自检断言与排障打印。
    /// 期望值 ~1e-9 px（双精度极限），远小于 0.5 px 的验收门槛。
    nonisolated static func roundTripPixelError(wx: Double, wy: Double) -> Double {
        let px = worldToMapPixelX(wx, wy)
        let py = worldToMapPixelY(wx, wy)
        let bx = mapPixelToWorldX(px, py)
        let by = mapPixelToWorldY(px, py)
        // 把世界坐标差值换算回像素：除以 A（≈0.0164 px/单位）
        let k = kCalibA
        return hypot((bx - wx) * k, (by - wy) * k)
    }

    // MARK: - 视口归一化（0~1，小地图视口内）

    /// 视野半径（米）。小地图固定展示自车周围这么多米的真实地图。
    static let minimapSpanMeters: Double = 160

    /// 自车在小地图视口内的归一化位置。
    /// 自车恒在视口中心（地图跟着车走），这是地图应用的标准做法；
    /// 未锁定时也给中心，由 UI 显示"等待网络定位"覆盖层。
    var egoNormX: Double { 0.5 }
    var egoNormY: Double { 0.5 }

    /// 任意世界坐标点 → 小地图视口归一化坐标（相对自车偏移换算）
    func normMapX(_ worldX: Double) -> Double {
        guard locatorFound else { return 0.5 }
        let px = Self.worldToMapPixelX(worldX, 0)
        let pxPerMeter = MapTileImage.mapPixels / MapTileImage.worldMetersPerMap
        let spanPx = Self.minimapSpanMeters * pxPerMeter
        let d = (px - mapPixelX) / spanPx
        return min(0.94, max(0.06, 0.5 + d))
    }

    func normMapY(_ worldY: Double) -> Double {
        guard locatorFound else { return 0.5 }
        let py = Self.worldToMapPixelY(0, worldY)
        let pxPerMeter = MapTileImage.mapPixels / MapTileImage.worldMetersPerMap
        let spanPx = Self.minimapSpanMeters * pxPerMeter
        let d = (py - mapPixelY) / spanPx
        return min(0.94, max(0.06, 0.5 + d))
    }
}

// ============================================================================
// MARK: - 地图数据库（FINAL_complete_map_database.json）
// ============================================================================
// 真实的离线地图数据库：5677 个标记点 + 100 个传送点 + 服务点等。
// 只读一次、常驻内存，供顶栏计数与地图标记使用。

enum MapDatabase {
    struct Marker {
        let name: String
        /// 地图坐标系（与 worldToMapPixel 输出同系），非世界坐标
        let mapX: Double?
        let mapY: Double?
        let kind: String
        /// 所属区域键（数据库 by_region 的键，如 new-herland）
        let region: String
        /// 原始世界坐标（数据库里的 x/y 字段）
        let worldX: Double
        let worldY: Double

        // ── 分类词表（2026-10-03 新增）────────────────────────────────────
        /// 稳定标识（数据库 id 字段）。词表按它键控，不用数组下标 ——
        /// 下标会随数据源增删而整体错位，id 不会。实测 5677 个全唯一。
        let id: String
        /// 语义组（explore/resource/travel/monster/shop/service/landmark）。
        /// 词表缺失时为 nil → UI 回落旧的 `kind` 配色。
        let group: String?
        /// 组中文名（「传送点」等），直接显示
        let groupLabel: String?
        /// 原始 icon basename（不含目录与扩展名），用于取 `models/map_icons/<name>.webp`
        let iconName: String?

        /// 组是否有效（词表命中）
        var hasGroup: Bool { group != nil }
    }

    private(set) static var markerCount: Int = 0
    private(set) static var markers: [Marker] = []
    private static var didLoad = false

    /// 地图数据库加载完成后置为 true，供 UI 重新求值（静态存储不触发 SwiftUI 更新）。
    private(set) static var loaded = false

    /// 幂等加载。找不到文件时计数为 0（UI 如实显示 0，不编造）。
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// ⚠️ 2026-09-30 修复：改为「首次调用只登记、后台线程加载」
    /// ══════════════════════════════════════════════════════════════════════
    ///
    /// 【症状】`open AuroraDriveUI.app` / Finder 双击启动时进程卡死在启动阶段，
    ///   CPU 时间近乎不增长，界面不出现、日志不再写出。
    ///
    /// 【根因】`sample` 抓到主线程栈恒停在：
    ///     ContentView.body.getter
    ///       → MapDatabase.ensureLoaded()
    ///         → NSData(contentsOfFile:)  → readBytesFromFile → open()
    ///   即：**在 SwiftUI 的 body 求值过程中同步读取 7.2 MB 的 JSON**
    ///   （`models/FINAL_complete_map_database.json`，5677 个标记点）。
    ///   body 求值发生在主线程的 layout 提交阶段（NSHostingView.layout →
    ///   ViewGraphRootValueUpdater.render），这里做磁盘 I/O 会直接把
    ///   窗口构建与事件循环一起拖住。
    ///
    /// 【为什么这是真问题，而不只是启动慢】
    ///   `ensureLoaded()` 原本在**三处**被调用（顶栏计数、大地图、标记查询），
    ///   其中 `:2853` 就在 `ContentView.body.getter` 的求值路径上。
    ///   只要界面第一次渲染，主线程就必须先读完 7.2 MB 并解析 JSON ——
    ///   这与「卡顿」的用户感受直接对应：**UI 线程在做磁盘 I/O**。
    ///
    /// 【修法】把「读文件 + 解析」整体移到后台队列，主线程立即返回。
    ///   · 用 `isLoading` 做并发保护（原 `didLoad` 仍是"已完成"标志）；
    ///   · 解析结果在主线程一次性落到 `markers` / `markerCount` / `loaded`，
    ///     与旧版语义一致（UI 靠 `loaded` 重新求值）；
    ///   · 调用方无需改动 —— `ensureLoaded()` 仍是幂等的，只是变成"发起加载"。
    ///   **行为等价**：数据内容、坐标系、计数全部不变，只是不再阻塞主线程。
    static func ensureLoaded() {
        // 已加载完成，或正在后台加载 —— 都立即返回（幂等，绝不重复加载）
        if didLoad || isLoading { return }
        isLoading = true

        DispatchQueue.global(qos: .utility).async {
            // ⚠️ 顺序关键：词表必须在解析标记**之前**就绪。
            //    标记的 `group` 字段是在解析时一次性写入的（避免每次访问都查表），
            //    若词表晚到，`group` 全为 nil → 地图回落成一片同色，
            //    而词表文件明明存在 —— 这种"数据对了但没生效"最难排查。
            //    这里已在后台线程，同步读词表不会卡主线程。
            MarkerTaxonomy.ensureLoadedSync()
            let result = loadFromDisk()
            DispatchQueue.main.async {
                // 主线程一次性落状态（静态存储不触发 SwiftUI 更新，靠 `loaded` 标志）
                if let r = result {
                    markers = r.markers
                    markerCount = r.markers.count
                    loaded = true
                    print("[MAPDB] 已加载 \(r.path) markers=\(r.markers.count)")
                } else {
                    print("[MAPDB] ✗ 未找到地图数据库（计数显示 0）")
                }
                didLoad = true
                isLoading = false
            }
        }
    }

    /// 是否正在后台加载（并发保护；`didLoad` 仍表示"已完成"）
    private static var isLoading = false

    /// 后台线程：纯 I/O + 解析，不触碰任何 UI 状态。
    /// 返回 nil 表示所有候选路径都不存在或解析失败。
    private static func loadFromDisk() -> (path: String, markers: [Marker])? {
        // 用 AuroraPaths.projectRoot() 定位：双击 .app 启动时 cwd 是 "/"，
        // 依赖 cwd 会找不到数据库（界面标记数显示 0）。
        let root = AuroraPaths.projectRoot()
        let cands = [
            root.appendingPathComponent("models/FINAL_complete_map_database.json").path,
            Bundle.main.resourceURL?.appendingPathComponent("FINAL_complete_map_database.json").path
        ].compactMap { $0 }

        for path in cands where FileManager.default.fileExists(atPath: path) {
            guard let data = FileManager.default.contents(atPath: path),
                  let rootObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard let all = rootObj["markers_all"] as? [[String: Any]] else {
                return (path, [])
            }
            let parsed = all.compactMap { m -> Marker? in
                guard let x = (m["x"] as? NSNumber)?.doubleValue,
                      let y = (m["y"] as? NSNumber)?.doubleValue else { return nil }
                // 数据库的 x/y 是**归一化百分比（0~100）**，对应整张 13056×13056 地图。
                // 直接换算成地图像素，与自车（worldToMapPixel 输出）处于同一坐标系。
                let mx = x / 100.0 * MapTileImage.mapPixels
                let my = y / 100.0 * MapTileImage.mapPixels
                let kind = (m["type"] as? String) ?? (m["kind"] as? String) ?? "landmark"
                let mid = (m["id"] as? String) ?? Self.syntheticID(name: (m["name"] as? String) ?? "",
                                                                  kind: kind, mx: mx, my: my)
                let g = MarkerTaxonomy.group(forMarker: mid)
                return Marker(name: (m["name"] as? String) ?? "",
                              mapX: mx, mapY: my,
                              kind: kind,
                              region: (m["_region_key"] as? String)
                                      ?? (m["region"] as? String) ?? "",
                              worldX: x, worldY: y,
                              id: mid,
                              group: g?.id,
                              groupLabel: g?.label,
                              iconName: Self.iconBase(m["icon"] as? String))
            }
            return (path, parsed)
        }
        return nil
    }

    /// icon 路径 → basename（去目录、去扩展名）。
    /// `".../YH_UI_Taxi_02.webp"` → `"YH_UI_Taxi_02"`
    /// 取 basename 而非整条路径，是因为取图标时按 `models/map_icons/<name>.webp`
    /// 查找 —— 数据源里的目录结构五花八门，只有文件名是稳的。
    static func iconBase(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let base = raw.split(separator: "/").last.map(String.init) ?? raw
        let noExt = base.split(separator: ".").first.map(String.init) ?? base
        return noExt.isEmpty ? nil : noExt
    }

    /// 数据源里 id 缺失时的合成 id（当前实测 5677 个全有 id，此为纯防御）。
    /// 用「类#名#坐标」保证稳定：同一条记录每次加载得到同样的 id，
    /// 否则词表会因 id 漂移而整体失配。
    static func syntheticID(name: String, kind: String, mx: Double, my: Double) -> String {
        "synth:\(kind)#\(name)#\(Int(mx))#\(Int(my))"
    }

    /// 旧实现（同步读盘）—— **仅离屏渲染夹具使用**（`--mc-map` 等）。
    ///
    /// 为什么保留：夹具是「一次性同步渲染」，没有"稍后 UI 再刷新"的机会，
    /// 故必须同步拿到 `markers` / `markerCount`。真机 UI 一律走异步版
    /// `ensureLoaded()`，避免在 `ContentView.body` 求值期阻塞主线程。
    ///
    /// 修复背景（供排障一眼看到被替换掉的原逻辑）：
    /// 原 `ensureLoaded()` 在主线程同步读 7.2 MB JSON，栈为
    /// `ContentView.body.getter → MapDatabase.ensureLoaded() → NSData(contentsOfFile:)`，
    /// 把窗口构建与事件循环一起拖住。
    static func ensureLoadedSyncLegacy() {
        guard !didLoad else { return }
        didLoad = true
        // ⚠️ 词表必须先就绪 —— 理由同 `ensureLoaded()`：标记的 group 字段
        //    在解析时一次性写入，词表晚到就会让整张图回落成一片同色。
        MarkerTaxonomy.ensureLoadedSync()
        // 用 AuroraPaths.projectRoot() 定位：双击 .app 启动时 cwd 是 "/"，
        // 依赖 cwd 会找不到数据库（界面标记数显示 0）。
        let root = AuroraPaths.projectRoot()
        let cands = [
            root.appendingPathComponent("models/FINAL_complete_map_database.json").path,
            Bundle.main.resourceURL?.appendingPathComponent("FINAL_complete_map_database.json").path
        ].compactMap { $0 }

        for path in cands where FileManager.default.fileExists(atPath: path) {
            guard let data = FileManager.default.contents(atPath: path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let all = root["markers_all"] as? [[String: Any]] {
                markers = all.compactMap { m in
                    guard let x = (m["x"] as? NSNumber)?.doubleValue,
                          let y = (m["y"] as? NSNumber)?.doubleValue else { return nil }
                    // 数据库的 x/y 是**归一化百分比（0~100）**，对应整张 13056×13056 地图。
                    // 直接换算成地图像素，与自车（worldToMapPixel 输出）处于同一坐标系。
                    let mx = x / 100.0 * MapTileImage.mapPixels
                    let my = y / 100.0 * MapTileImage.mapPixels
                    let kind = (m["type"] as? String) ?? (m["kind"] as? String) ?? "landmark"
                    let mid = (m["id"] as? String) ?? syntheticID(name: (m["name"] as? String) ?? "",
                                                                  kind: kind, mx: mx, my: my)
                    let g = MarkerTaxonomy.group(forMarker: mid)
                    return Marker(name: (m["name"] as? String) ?? "",
                                  mapX: mx, mapY: my,
                                  kind: kind,
                                  region: (m["_region_key"] as? String)
                                          ?? (m["region"] as? String) ?? "",
                                  worldX: x, worldY: y,
                                  id: mid,
                                  group: g?.id,
                                  groupLabel: g?.label,
                                  iconName: iconBase(m["icon"] as? String))
                }
                markerCount = markers.count
            }
            loaded = true
            print("[MAPDB] 已加载 \(path) markers=\(markerCount)")
            return
        }
        print("[MAPDB] ✗ 未找到地图数据库（计数显示 0）")
    }
}


// ============================================================================
// MARK: - 视野内标记查询（大地图渲染用）
// ============================================================================

extension MapDatabase {
    /// 屏幕上可绘制的一个标记（已算好地图像素坐标）
    ///
    /// 2026-10-03：新增 `id` / `group` / `groupLabel` / `iconName`，
    /// 并把 `stableID` 改用 `id` —— 原来拼「kind#name#x#y」在 5677 条里有
    /// 大量同名同类的点（533 个「遗失的钱包」），字符串重复率高、
    /// 且坐标取整后仍可能碰撞，不利于 SwiftUI 身份判别。
    struct PlacedMarker {
        let name: String
        let kind: String
        let mapX: Double
        let mapY: Double
        /// 稳定标识（来自数据库 id）
        let id: String
        let group: String?
        let groupLabel: String?
        let iconName: String?
        // 存储属性（init 里算一次）：四项输入全是 let，创建后不变。
        // 原计算属性在 ForEach 身份求解时每次重绘都重建字符串。
        let stableID: String

        init(name: String, kind: String, mapX: Double, mapY: Double,
             id: String, group: String?, groupLabel: String?, iconName: String?) {
            self.name = name
            self.kind = kind
            self.mapX = mapX
            self.mapY = mapY
            self.id = id
            self.group = group
            self.groupLabel = groupLabel
            self.iconName = iconName
            self.stableID = id
        }

        /// 组色（词表缺失时回落 kind 配色）
        var color: Color {
            if let gid = group,
               let g = MarkerTaxonomy.groups.first(where: { $0.id == gid }) {
                return g.color
            }
            return MapDatabase.color(for: kind)
        }
    }

    /// 取落在「以 (centerX,centerY) 为中心、边长 spanPx 的方形视野」内的标记。
    /// 按到中心的距离由近及远排序，最多返回 limit 个 —— 保证近处细节优先绘制。
    static func markersInView(centerX: Double, centerY: Double,
                              spanPx: Double, limit: Int) -> [PlacedMarker] {
        ensureLoaded()
        guard spanPx > 0, !markers.isEmpty else { return [] }
        let half = spanPx / 2
        var hit: [(Double, PlacedMarker)] = []
        hit.reserveCapacity(256)
        for m in markers {
            // markers 的 x/y 已是地图坐标系（与 worldToMapPixel 输出同系）
            let mx = m.mapX ?? 0, my = m.mapY ?? 0
            let dx = mx - centerX, dy = my - centerY
            if abs(dx) <= half, abs(dy) <= half {
                hit.append((dx * dx + dy * dy,
                            PlacedMarker(name: m.name, kind: m.kind, mapX: mx, mapY: my,
                                         id: m.id, group: m.group,
                                         groupLabel: m.groupLabel, iconName: m.iconName)))
            }
        }
        hit.sort { $0.0 < $1.0 }
        return hit.prefix(limit).map { $0.1 }
    }

    /// 取视野内标记，**不做数量截断**（聚类路径用）。
    ///
    /// 与 `markersInView` 的区别：那个带 `limit`（旧 ForEach 路径靠它保命），
    /// 聚类必须先拿到全部点才能正确成团 —— 先截断再聚类会把团计数算错。
    static func markersInViewAll(centerX: Double, centerY: Double,
                                 spanPx: Double) -> [PlacedMarker] {
        ensureLoaded()
        guard spanPx > 0, !markers.isEmpty else { return [] }
        let half = spanPx / 2
        var out: [PlacedMarker] = []
        out.reserveCapacity(1024)
        for m in markers {
            let mx = m.mapX ?? 0, my = m.mapY ?? 0
            if abs(mx - centerX) <= half, abs(my - centerY) <= half {
                out.append(PlacedMarker(name: m.name, kind: m.kind, mapX: mx, mapY: my,
                                        id: m.id, group: m.group,
                                        groupLabel: m.groupLabel, iconName: m.iconName))
            }
        }
        return out
    }

    /// 区域键 → 中文名。优先用数据库里的 _region_cn，缺省时按已知键映射。
    static let regionNamesCN: [String: String] = [
        "new-herland":      "新赫兰",
        "bridge-crossings": "桥区",
        "unheard-shores":   "无人海岸",
        "miguel-district":  "米格尔区",
        "illusion-town":    "幻象镇",
    ]

    /// 由实时定位坐标反查当前所在区域（取最近标记的 region —— 真实数据推导）。
    /// 最近一次区域查询的格缓存。regionName 唯一调用方是 DriveState.regionLabel
    ///（UI body，主线程），而自车在格内缓慢移动时每次求值都全量遍历 5677 个
    /// 标记纯属重复：坐标取整到 100px 一格，同格直接命中缓存，只在跨格时
    /// 遍历一次（120km/h ≈ 每秒十几次跨格，vs 原来每次求值都遍历）。
    /// 仅主线程访问（唯一调用方在 body），nonisolated(unsafe) 无锁读写在
    /// 单线程下成立。
    private static var lastRegionQuery: (gx: Int, gy: Int, name: String?)?

    static func regionName(atMapX mx: Double, mapY my: Double) -> String? {
        ensureLoaded()
        guard !markers.isEmpty else { return nil }
        // 格缓存：同格（100px ≈ 数米）内直接返回上次结果
        let gx = Int(mx / 100), gy = Int(my / 100)
        if let last = lastRegionQuery, last.gx == gx, last.gy == gy {
            return last.name
        }
        var best: (Double, String)?
        for m in markers {
            guard let px = m.mapX, let py = m.mapY else { continue }
            let d = (px - mx) * (px - mx) + (py - my) * (py - my)
            if best == nil || d < best!.0 { best = (d, m.region) }
        }
        guard let key = best?.1, !key.isEmpty else {
            lastRegionQuery = (gx, gy, nil)
            return nil
        }
        let name = regionNamesCN[key] ?? key
        lastRegionQuery = (gx, gy, name)
        return name
    }

    /// 标记类型 → 颜色（沿用极光配色，不引入新色）
    ///
    /// ⚠️ 2026-10-03 修复：`phone_booth` 用**下划线**匹配，而数据源里
    ///   `type` 字段是 `phone-booth`（**连字符**）—— 17 个电话亭全部落进
    ///   `default` 分支，显示成默认冰蓝，与最普通的点毫无区别。
    ///   现在两种写法都接受（保留旧值，纯增量，不影响既有调用）。
    ///
    /// 注意：**分组着色优先走 `MarkerTaxonomy`**（按 `group` 字段）；
    /// 本函数是词表缺失时的回落路径。两条路都要能正确上色。
    static func color(for kind: String) -> Color {
        switch kind.lowercased() {
        case "waypoint", "传送点":   return Aurora.amber
        case "shop", "商店":         return Aurora.iceHi
        case "service", "服务":      return Aurora.ok
        case "tower", "塔":          return Aurora.violet
        // ⚠️ 连字符与下划线都接受 —— 数据源用连字符，历史代码写的是下划线
        case "phone-booth", "phone_booth", "电话亭": return Aurora.t3
        default:                     return Aurora.ice
        }
    }

    /// 标记着色：**优先按分类组**，词表缺失时回落旧的 `kind` 配色。
    /// 这是 UI 唯一的取色入口 —— 不要再直接调 `color(for:)`，
    /// 否则词表生效时分组的颜色就会与图例对不上。
    static func color(for marker: Marker) -> Color {
        if let gid = marker.group,
           let g = MarkerTaxonomy.groups.first(where: { $0.id == gid }) {
            return g.color
        }
        return color(for: marker.kind)
    }
}

extension DriveState {
    /// 大地图归一化坐标（相对自车视野）
    func normMapXLarge(_ worldX: Double, spanPx: Double) -> Double {
        let px = Self.worldToMapPixelX(worldX, 0)
        return min(0.97, max(0.03, (px - mapPixelX) / spanPx + 0.5))
    }
    func normMapYLarge(_ worldY: Double, spanPx: Double) -> Double {
        let py = Self.worldToMapPixelY(0, worldY)
        return min(0.97, max(0.03, (py - mapPixelY) / spanPx + 0.5))
    }
}
