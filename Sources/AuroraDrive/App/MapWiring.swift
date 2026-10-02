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
    static func worldToMapPixelX(_ wx: Double, _ wy: Double) -> Double {
        kCalibA * wx + kCalibB * wy + kCalibTX
    }

    /// 世界坐标 Y（UE5 厘米）→ 地图像素 Y
    static func worldToMapPixelY(_ wx: Double, _ wy: Double) -> Double {
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
                return Marker(name: (m["name"] as? String) ?? "",
                              mapX: mx, mapY: my,
                              kind: (m["type"] as? String) ?? (m["kind"] as? String) ?? "landmark",
                              region: (m["_region_key"] as? String)
                                      ?? (m["region"] as? String) ?? "",
                              worldX: x, worldY: y)
            }
            return (path, parsed)
        }
        return nil
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
                    return Marker(name: (m["name"] as? String) ?? "",
                                  mapX: mx, mapY: my,
                                  kind: (m["type"] as? String) ?? (m["kind"] as? String) ?? "landmark",
                                  region: (m["_region_key"] as? String)
                                          ?? (m["region"] as? String) ?? "",
                                  worldX: x, worldY: y)
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
    struct PlacedMarker {
        let name: String
        let kind: String
        let mapX: Double
        let mapY: Double
        // 存储属性（init 里算一次）：四项输入全是 let，创建后不变。
        // 原计算属性在 ForEach 身份求解时每次重绘都重建字符串。
        let stableID: String

        init(name: String, kind: String, mapX: Double, mapY: Double) {
            self.name = name
            self.kind = kind
            self.mapX = mapX
            self.mapY = mapY
            self.stableID = "\(kind)#\(name)#\(Int(mapX))#\(Int(mapY))"
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
                            PlacedMarker(name: m.name, kind: m.kind, mapX: mx, mapY: my)))
            }
        }
        hit.sort { $0.0 < $1.0 }
        return hit.prefix(limit).map { $0.1 }
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
    static func color(for kind: String) -> Color {
        switch kind.lowercased() {
        case "waypoint", "传送点":   return Aurora.amber
        case "shop", "商店":         return Aurora.iceHi
        case "service", "服务":      return Aurora.ok
        case "tower", "塔":          return Aurora.violet
        case "phone_booth", "电话亭": return Aurora.t3
        default:                     return Aurora.ice
        }
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
