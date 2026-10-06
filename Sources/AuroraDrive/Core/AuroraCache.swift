// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  AuroraCache.swift — 全 App 统一缓存层（A16）
// ============================================================================
//
//  【为什么要有这个文件】
//  用户明确授权：「我甚至可以给你一个权限，可以在这一整个 App 里加上缓存功能，
//  就是**一整个**加上缓存」。
//
//  而改造前的现状（`perf-core` 全量盘点，20 个缓存）是：
//    · 5 个「单条目覆盖式」缓存（`MapTileCache.cached` / `RoadOverlayCache.cached` /
//      `clusterCache` / `EngineClient.frameCache` …）—— 换个视野必 miss，等于没缓存；
//    · 各写各的淘汰策略（有的是覆盖、有的是 2s TTL、有的完全无上限）；
//    · **零指标** —— 没有一个缓存能回答「命中率多少」；
//    · **零统一开关** —— 想 A/B 对比「有缓存 vs 无缓存」只能改代码。
//
//  本文件提供统一抽象，把上面四件事一次解决。
//
//  ────────────────────────────────────────────────────────────────────────
//  【为什么不用 NSCache】（这是本文件最重要的设计决策）
//  ────────────────────────────────────────────────────────────────────────
//  `NSCache` 看起来是"系统给的、还自动响应内存压力"，但它的四个限制恰好
//  每一条都踩在本项目的痛点上：
//
//   ① **键必须是类实例（`AnyObject`）**。本项目的缓存键是**复合值**：
//      `(centerX, centerY, spanPx, outSize, level, flags, generation)`。
//      用 `NSString` 拼键会每帧产生字符串分配 —— 正是我们要消灭的东西。
//   ② **没有 TTL**。`PrivilegePill`（2s）/ `CoordinateCapture`（5s）都需要。
//   ③ **没有指标**。`NSCache` 不暴露 hits/misses/evictions。
//      而本项目的第一纪律是「性能必须先有基线」—— 没有命中率的缓存
//      无法判断该不该留（金字塔 202MB 换零收益就是靠端到端测量才发现的）。
//   ④ **淘汰不可预测**。`NSCache` 的淘汰时机由系统决定，
//      排查「为什么这张被淘汰了」时无从下手。
//
//  所以：**自建 LRU（字典 + 双向链表）**，`OSAllocatedUnfairLock` 保护。
//  内存压力响应不丢 —— 见下面 `memoryPressureSource`，注册
//  `DispatchSource.makeMemoryPressureSource` 在 `.warning/.critical` 时整体清空，
//  等价拿到 `NSCache` 的那项能力，同时保留完全控制权。
//
//  ────────────────────────────────────────────────────────────────────────
//  【generation：一等公民，不是可选装饰】
//  ────────────────────────────────────────────────────────────────────────
//  本项目已经**两次**踩过"数据换版但缓存没换"的坑：
//    · `MapTileCache` 注释：「缓存键**必须含层级**，否则近景用原图、远景用 1/2 档时，
//      同一个视野参数会命中错误分辨率的旧图（表现为"突然变糊"）」
//    · `RoadOverlayCache` 后来补了 `gen` 参数
//  故本类把 `generation` 做进**每条记录**：数据换版时调 `invalidateGeneration()`，
//  旧记录在下一次被访问时**惰性失效**（不遍历、不清表，O(1)）。
//  这比"遍历清表"安全：清表期间并发写入不会漏网。
//
//  ────────────────────────────────────────────────────────────────────────
//  【一键 A/B：AURORA_CACHE=0】
//  ────────────────────────────────────────────────────────────────────────
//  `AuroraCacheSwitch.enabled == false` 时 `value(for:compute:)` **直通 compute**，
//  不读不写不计数。用于 ABBA 对比「有缓存 vs 无缓存」——
//  与项目既有的 `AURORA_*` 诊断开关同一约定（见 `AuroraFlags`）。
//  这是本项目的硬纪律：没有开关的优化做不了 A/B，做不了 A/B 的优化不算数。
//
//  ────────────────────────────────────────────────────────────────────────
//  【怎么用】
//  ────────────────────────────────────────────────────────────────────────
//      private let tileCache = AuroraCache<TileKey, CGImage>(
//          name: "map.tile", capacity: 64, costLimit: 64 << 20,
//          cost: { $0.width * $0.height * 4 })
//
//      let img = tileCache.value(for: key) { renderTile(key) }
//
//  自测：`AuroraCacheSelfTest.run()`（挂 `--cache-selftest`，见 `AuroraFlags`）。
// ============================================================================

import Foundation
import os
// `CACurrentMediaTime()` 声明在 QuartzCore/CABase.h，**不在 Foundation**。
// 单调时钟（不受系统时间调整影响），缓存 TTL 必须用它而不是 `Date()`。
import QuartzCore

// MARK: - 指标

// MARK: - 非泛型开关载体

/// 缓存层的全局开关（**非泛型载体**）。
///
/// 【为什么必须单独放一个 enum】
/// `AuroraCache` 是泛型类 `AuroraCache<Key, Value>`。Swift 里**泛型类型的静态成员
/// 需要特化**才能访问 —— 从外部写 `AuroraCacheSwitch.enabled` 会直接报：
///     error: generic parameter 'Key' could not be inferred
///           generic parameter 'Value' could not be inferred
/// 而这个开关**在语义上与 Key/Value 毫无关系**（它是"整个缓存层开不开"），
/// 强行写成 `AuroraCache<Int, CGImage>.enabled` 是把实现细节泄漏给调用方。
/// 故提到这个非泛型 enum 上 —— 调用方一律用 `AuroraCacheSwitch.enabled`。
///
/// 这个坑是 `site-main` 在 build 阻塞时帮我定位的（我最初误判成多语句闭包的
/// 泛型推断问题）。记在这里，避免下一个人重踩。
enum AuroraCacheSwitch {
    /// `AURORA_CACHE=0` → 全部直通（ABBA 对比用）。
    /// 单一事实源在 `AuroraFlags`（A17 集中化的 66 个开关之一）。
    static var enabled: Bool { AuroraFlags.cacheEnabled }
}

/// 缓存指标快照。**不可变值类型** —— 取指标不应该影响缓存状态。
struct AuroraCacheMetrics: Sendable {
    let name: String
    /// 当前条目数
    let count: Int
    /// 当前占用字节（由 `cost` 闭包累加得出）
    let bytes: Int
    let hits: Int
    let misses: Int
    /// 因容量/字节超限被淘汰
    let evictions: Int
    /// 因 TTL 过期被丢弃
    let expirations: Int
    /// 因 generation 不匹配被丢弃
    let generationMisses: Int
    /// 因内存压力被整体清空的次数
    let pressureFlushes: Int
    let generation: UInt64
    /// 平均查找耗时（毫秒）—— 含命中的链表操作与未命中的 compute
    let avgLookupMs: Double

    var lookups: Int { hits + misses }
    /// 命中率 [0,1]；无查找时为 0（**不是 1**，避免"没数据看起来很好"）
    var hitRate: Double { lookups > 0 ? Double(hits) / Double(lookups) : 0 }

    var oneLine: String {
        String(format: "%@: %d 条/%.1fMB  命中 %d/%d=%.1f%%  淘汰 %d(容量)+%d(TTL)+%d(gen)  压力清空 %d  平均 %.3fms",
               name, count, Double(bytes) / 1_048_576.0,
               hits, lookups, hitRate * 100,
               evictions, expirations, generationMisses, pressureFlushes, avgLookupMs)
    }
}

// MARK: - 缓存主体

/// 统一 LRU 缓存。
///
/// 线程安全：内部 `OSAllocatedUnfairLock` 保护全部可变状态，可从任意线程调用。
/// 用 `withLockUnchecked` 而非 `withLock` —— 后者要求闭包 `@Sendable` 且返回值
/// `Sendable`，而缓存值常常是 `CGImage` 这类非 Sendable 类型。锁本身仍是
/// `os_unfair_lock`（不优先级反转），只是不施加编译期 Sendable 约束。
///
/// ══════════════════════════════════════════════════════════════════════════
/// ⚠️ **使用约束：每个 `AuroraCache` 实例都持有系统资源，必须长生命周期**
/// ══════════════════════════════════════════════════════════════════════════
/// `init` 里做了两件事：
///   ① `installMemoryPressureSource()` —— 注册一个 `DispatchSourceMemoryPressure`
///   ② `installMetricsTimerIfNeeded()` —— **仅当 `AURORA_PERF=1`** 时再注册一个定时器
///
/// 所以**实例数 = 系统资源数**。如果把缓存放进"随视图身份重建"的宿主
/// （`@StateObject` / 每次 body 新建的对象），就会**成倍地装 source**。
///
/// 【实测教训（2026-10-04，perf-app-ui 抓到）】
///   `ClusterCacheStore` 最初按建议写成 `@StateObject`，而基准夹具**每轮新建 6 个视图**、
///   200 轮 → **2400 个 memory-pressure source**。配对 A/B 测到
///   `Canvas+聚类` p50 **11.51 → 15.96ms（+40.8%）**、线程数 **7 → 12**。
///   改成**进程级单例**（`ClusterCacheStore.shared`，与 `MapTileCache.shared` /
///   `RoadOverlayCache.shared` 同一约定）后恢复正常。
///
/// 【结论】缓存实例应当**进程级长生命周期**：
///   · 优先 `static let shared`（与项目既有约定一致）；
///   · 若必须多实例，请让宿主生命周期与进程同长（`@StateObject` 挂在**根视图**上，
///     而不是挂在会重建的子视图上）。
///   ⚠️ 本类**不是**"随手 new 一个就行"的工具类 —— 它带系统资源。
///
/// 【将来若确实需要大量短命实例】正确做法是把内存压力源提到**非泛型的共享注册表**
///   （一个 source 服务所有实例），而不是每实例一个。当前项目没有这个需求，故未做。
final class AuroraCache<Key: Hashable & Sendable, Value>: @unchecked Sendable {

    // MARK: 节点（侵入式双向链表）

    private final class Node: @unchecked Sendable {
        let key: Key
        var value: Value
        let cost: Int
        /// 写入时刻（`CACurrentMediaTime()`，单调时钟，不受系统时间调整影响）
        let bornAt: Double
        /// 写入时的世代号
        let gen: UInt64
        var prev: Node?
        var next: Node?

        init(key: Key, value: Value, cost: Int, bornAt: Double, gen: UInt64) {
            self.key = key
            self.value = value
            self.cost = cost
            self.bornAt = bornAt
            self.gen = gen
        }
    }

    // MARK: 内部状态

    private struct State: Sendable {
        var map: [Key: Node] = [:]
        /// 最近使用（MRU）
        var head: Node?
        /// 最久未用（LRU）—— 淘汰从这里摘
        var tail: Node?
        var bytes = 0
        var generation: UInt64 = 0

        var hits = 0
        var misses = 0
        var evictions = 0
        var expirations = 0
        var generationMisses = 0
        var pressureFlushes = 0

        var lookupCount = 0
        var lookupTotalMs = 0.0
    }

    // MARK: 配置

    let name: String
    /// 条目数上限
    let capacity: Int
    /// 字节上限；`0` = 不限（此时只受 `capacity` 约束）
    let costLimit: Int
    /// 生存时间；`nil` = 不按时间过期
    let ttl: TimeInterval?

    private let costOf: (Value) -> Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// 内存压力源。`.warning` / `.critical` 时整体清空。
    ///
    /// 为什么每个实例各持一个而不是全局共用一个：压力源**不是唤醒源**
    /// （只在系统真的发压力事件时触发），实例数 < 10，多几个源的代价可忽略；
    /// 而全局共享需要一张非泛型的注册表（泛型类型的 static 存储属性是按
    /// 特化各存一份的，做不了"全局唯一"），复杂度不值当。
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// 指标推送定时器。**仅在 `PerfBus.enabled` 时启动** —— 生产默认关闭，
    /// 因此生产环境**零定时器、零唤醒**。
    private var metricsTimer: DispatchSourceTimer?

    // MARK: 开关

    /// 全局开关。`AURORA_CACHE=0` → 全部直通，用于 ABBA 对比。
    ///
    /// ⚠️ **类内的静态成员需要泛型特化**：`AuroraCache<Key, Value>` 是泛型类型，
    /// 从**外部**写 `AuroraCacheSwitch.enabled` 会报
    /// `generic parameter 'Key'/'Value' could not be inferred`。
    /// 故对外一律用非泛型载体 `AuroraCacheSwitch.enabled`（见下方）。
    /// 类内部用 `Self.enabled` 没问题（`Self` 已经是具体特化）。
    static var enabled: Bool { AuroraCacheSwitch.enabled }

    // MARK: 初始化

    /// - Parameters:
    ///   - name: 指标通道名（会出现在 `PerfBus` 里，建议 `"map.tile"` 这种点分名）
    ///   - capacity: 条目数上限（<=0 视为 1，避免"配成 0 却期望能存"的静默失效）
    ///   - costLimit: 字节上限；0 = 不限
    ///   - ttl: 生存时间；nil = 不过期
    ///   - cost: 单条成本（字节）。默认按"1 条 = 1 字节"计，即只受 capacity 约束。
    init(name: String,
         capacity: Int,
         costLimit: Int = 0,
         ttl: TimeInterval? = nil,
         cost: @escaping (Value) -> Int = { _ in 1 }) {
        self.name = name
        self.capacity = max(1, capacity)
        self.costLimit = max(0, costLimit)
        self.ttl = ttl
        self.costOf = cost

        installMemoryPressureSource()
        installMetricsTimerIfNeeded()
    }

    deinit {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        metricsTimer?.cancel()
        metricsTimer = nil
    }

    // MARK: - 主入口

    /// 取缓存值；未命中时调 `compute` 并写入。
    ///
    /// - 命中：返回值 + 提升到 MRU + `hits += 1`
    /// - 未命中（不存在 / TTL 过期 / generation 不符 / 已禁用）：`compute()` + 写入
    ///
    /// ⚠️ `compute` **在锁外执行**：渲染一张瓦片可能几十毫秒，持锁算它会把
    /// 所有并发查找一起堵死。代价是同一 key 的并发未命中可能重复计算 ——
    /// 对本项目可接受（缓存的值都是纯函数产物，重复算只是浪费不算错）。
    func value(for key: Key, compute: () -> Value) -> Value {
        guard Self.enabled else { return compute() }   // A/B 直通

        let t0 = CACurrentMediaTime()
        let now = t0

        // ── 快路径：查表（持锁）──
        var hitValue: Value?
        state.withLockUnchecked { s in
            s.lookupCount += 1
            if let n = s.map[key] {
                if let ttl, now - n.bornAt > ttl {
                    remove(n, &s)
                    s.expirations += 1
                } else if n.gen != s.generation {
                    remove(n, &s)
                    s.generationMisses += 1
                } else {
                    moveToFront(n, &s)
                    s.hits += 1
                    hitValue = n.value
                }
            }
        }
        if let v = hitValue {
            state.withLockUnchecked { $0.lookupTotalMs += (CACurrentMediaTime() - t0) * 1000 }
            return v
        }

        // ── 慢路径：算 + 写（compute 在锁外）──
        let fresh = compute()
        insert(fresh, for: key)

        state.withLockUnchecked { s in
            s.misses += 1
            s.lookupTotalMs += (CACurrentMediaTime() - t0) * 1000
        }
        return fresh
    }

    /// 只查不算。**不计 hit/miss**（用于"有没有"这类探测，不污染命中率）。
    func peek(_ key: Key) -> Value? {
        guard Self.enabled else { return nil }
        var out: Value?
        state.withLockUnchecked { s in
            guard let n = s.map[key], n.gen == s.generation else { return }
            if let ttl, CACurrentMediaTime() - n.bornAt > ttl { return }
            out = n.value
        }
        return out
    }

    /// 主动写入（不触发 `compute`）。已有同 key 则覆盖。
    func insert(_ value: Value, for key: Key) {
        guard Self.enabled else { return }
        let c = costOf(value)
        state.withLockUnchecked { s in
            if let old = s.map[key] { remove(old, &s) }
            let n = Node(key: key, value: value, cost: c,
                         bornAt: CACurrentMediaTime(), gen: s.generation)
            s.map[key] = n
            s.bytes += c
            pushFront(n, &s)
            evictIfNeeded(&s)
        }
    }

    // MARK: - 失效

    /// 按条件失效（会遍历全部键；只在配置变更这类低频场合用）。
    func invalidate(where predicate: (Key) -> Bool) {
        state.withLockUnchecked { s in
            // 先收集再删：遍历中改字典是未定义行为
            let doomed = s.map.keys.filter(predicate)
            for k in doomed { if let n = s.map[k] { remove(n, &s) } }
        }
    }

    /// 清空全部条目（**保留指标与世代号** —— 指标是累计量，不该被清空重置，
    /// 否则"压力清空"之后命中率会假装回到 100%）。
    func invalidateAll() {
        state.withLockUnchecked { s in
            s.map.removeAll(keepingCapacity: false)
            s.head = nil
            s.tail = nil
            s.bytes = 0
        }
    }

    /// 数据换版：世代号 +1 → 全部旧条目**惰性失效**（O(1)，不遍历）。
    ///
    /// 为什么不直接 `invalidateAll()`：清表会让"清空瞬间并发写入的新数据"
    /// 与"正在被读的旧数据"混在一起；而世代号是**记录级**的，
    /// 旧记录在下一次被访问时才丢弃，不存在竞态窗口。
    func invalidateGeneration() {
        state.withLockUnchecked { $0.generation &+= 1 }
    }

    /// 当前世代号（供调用方在日志里对账）
    var generation: UInt64 {
        state.withLockUnchecked { $0.generation }
    }

    // MARK: - 指标

    /// 诊断：**metrics 推送定时器是否活着**。
    ///
    /// 生产模式（`AURORA_PERF` 未设）下**必须为 `false`** ——
    /// `installMetricsTimerIfNeeded()` 开头就是 `guard PerfBus.enabled else { return }`，
    /// 定时器**根本不创建**，所以生产环境是"零定时器、零唤醒"，不是"定时器空转"。
    ///
    /// 【为什么需要这个访问器】只靠代码里的 `guard` 是**论证**，不是**证据**。
    ///   而"生产有没有多一个定时器"这件事，用 `ps -M` 数线程是**数不出来**的 ——
    ///   `DispatchSource.makeTimerSource` 用的是共享的全局队列线程池，不新建专属线程
    ///   （实测：生产 3 线程 / 测量 3 线程，差 0，方法不敏感）。
    ///   本访问器把"定时器在不在"变成一个**可断言的布尔值**，于是
    ///   `--cache-selftest` 能给出**经验性证明**而不是复述代码。
    ///
    /// 【为什么这不叫"往生产代码里塞测试代码"】它与项目既有的
    ///   `RoadOverlayCache.lastRenderMs` / `renderCount` / `hitCount` **完全同类**：
    ///   只读诊断访问器，不参与任何行为路径、不改变任何分支。
    var metricsTimerActive: Bool { metricsTimer != nil }

    var metrics: AuroraCacheMetrics {
        state.withLockUnchecked { s in
            AuroraCacheMetrics(
                name: name,
                count: s.map.count,
                bytes: s.bytes,
                hits: s.hits,
                misses: s.misses,
                evictions: s.evictions,
                expirations: s.expirations,
                generationMisses: s.generationMisses,
                pressureFlushes: s.pressureFlushes,
                generation: s.generation,
                avgLookupMs: s.lookupCount > 0 ? s.lookupTotalMs / Double(s.lookupCount) : 0)
        }
    }

    /// 把指标推进 `PerfBus`，让 `--perf-selftest` 能直接读出来。
    ///
    /// ⚠️ 单位说明（重要，别误读）：`PerfBus.record(_:ms:)` 的第二个参数语义是
    /// "毫秒"，而这里推的 `hitPct` 通道值是**百分比**。通道名已带 `Pct` 后缀
    /// 明确区分。之所以复用这个 API 而不是新造一个计数器通道，是为了**不改
    /// `PerfSelfTest.swift`**（那是别人的写域）——`PerfStats` 的 `mean` 对
    /// 百分比同样有意义，p50/p95 无意义，读的时候看 mean 即可。
    func publishMetrics() {
        guard PerfBus.enabled else { return }
        let m = metrics
        PerfBus.shared.record("cache.\(name).hitPct", ms: m.hitRate * 100)
        PerfBus.shared.record("cache.\(name).lookupMs", ms: m.avgLookupMs)
        PerfBus.shared.record("cache.\(name).entries", ms: Double(m.count))
        PerfBus.shared.record("cache.\(name).mb", ms: Double(m.bytes) / 1_048_576.0)
    }

    // MARK: - 链表维护（全部在持锁状态下调用）

    private func pushFront(_ n: Node, _ s: inout State) {
        n.prev = nil
        n.next = s.head
        s.head?.prev = n
        s.head = n
        if s.tail == nil { s.tail = n }
    }

    private func moveToFront(_ n: Node, _ s: inout State) {
        guard s.head !== n else { return }
        // 摘下
        n.prev?.next = n.next
        n.next?.prev = n.prev
        if s.tail === n { s.tail = n.prev }
        // 挂到头部
        n.prev = nil
        n.next = s.head
        s.head?.prev = n
        s.head = n
    }

    private func remove(_ n: Node, _ s: inout State) {
        n.prev?.next = n.next
        n.next?.prev = n.prev
        if s.head === n { s.head = n.next }
        if s.tail === n { s.tail = n.prev }
        n.prev = nil
        n.next = nil
        s.map.removeValue(forKey: n.key)
        s.bytes -= n.cost
    }

    private func evictIfNeeded(_ s: inout State) {
        while s.map.count > capacity || (costLimit > 0 && s.bytes > costLimit) {
            guard let victim = s.tail else { break }   // 空表，防死循环
            remove(victim, &s)
            s.evictions += 1
        }
    }

    // MARK: - 系统集成

    private func installMemoryPressureSource() {
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility))
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // 不调 invalidateAll()：要顺带把 pressureFlushes 计上，
            // 否则"被系统清空过几次"这个关键事实在指标里看不见。
            self.state.withLockUnchecked { s in
                s.map.removeAll(keepingCapacity: false)
                s.head = nil
                s.tail = nil
                s.bytes = 0
                s.pressureFlushes += 1
            }
        }
        src.resume()
        memoryPressureSource = src
    }

    /// 只在 `PerfBus.enabled`（`AURORA_PERF=1`）时起 1Hz 推送定时器。
    /// 生产默认关闭 → **零定时器**。这是"零开销"的实现方式：
    /// 不是让定时器空转，而是根本不创建。
    private func installMetricsTimerIfNeeded() {
        guard PerfBus.enabled else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.publishMetrics() }
        t.resume()
        metricsTimer = t
    }
}

// MARK: - 自测

/// `AuroraCache` 自测（挂 `--cache-selftest`）。
///
/// 覆盖验收要求的五种情形：hit / miss / evict / TTL / generation。
/// 另加：capacity 与 costLimit 两条淘汰路径、以及 `AURORA_CACHE=0` 直通。
///
/// - Returns: 失败项数（0 = 全过）
enum AuroraCacheSelfTest {

    private static var failures = 0
    private static var checks = 0
    /// 被跳过的用例组数（仅 `AURORA_CACHE=0` 直通模式下 > 0）。
    /// 与 `failures` 分开计数：**跳过不是失败**，混在一起会让这条 A/B 通路恒红。
    private static var skipped = 0

    private static func ck(_ cond: Bool, _ label: String, _ detail: String = "") {
        checks += 1
        if !cond { failures += 1 }
        print("  \(cond ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    }

    static func run() -> Int {
        failures = 0
        checks = 0
        skipped = 0
        print("═══ AuroraCache 自测（--cache-selftest）═══")
        print("  全局开关 AURORA_CACHE → enabled=\(AuroraCacheSwitch.enabled)")
        print("")

        // ══════════════════════════════════════════════════════════════════════
        // ⚠️ 直通模式下必须**跳过** ①~⑥，而不是让它们判红
        // ══════════════════════════════════════════════════════════════════════
        // 【为什么】`AURORA_CACHE=0` 时 `value(for:compute:)` 直接 `return compute()`，
        //   缓存**根本不写不读** —— 于是"命中""淘汰""TTL""generation"这些行为
        //   在语义上**不存在**。让它们判红等于说"关掉缓存之后缓存不工作"，
        //   这是把"预期行为"误报成"缺陷"。
        //
        // 【代价有多大】这条命令是 `AURORA_CACHE=0` 这条 **A/B 通路**的唯一入口。
        //   如果它恒为红，CI 里就会长期挂一条假红灯，最终被人忽略 ——
        //   等于把用户明确授权的"一键关闭缓存做对照"这个能力废掉。
        //
        // 【谁发现的】site-pph 在接线后按约定复跑 `AURORA_CACHE=0`，实测
        //   FAIL 19/27 并把这个现象报了回来（他只报现象、没替我改，做法很对）。
        // ══════════════════════════════════════════════════════════════════════
        if AuroraCacheSwitch.enabled {
            testHitAndMiss()
            testEvictionByCapacity()
            testEvictionByCost()
            testTTL()
            testGeneration()
            testInvalidateWhere()
        } else {
            skipped = 6
            print("── ① ~ ⑥ 已跳过 ──")
            print("  ⏭️  AURORA_CACHE=0 → 缓存整体直通，命中/淘汰/TTL/generation")
            print("      这些行为在直通模式下**不存在**，故不计入失败。")
            print("      本模式只验证 ⑦（直通语义）。")
        }
        testDisabledPassthrough()
        testMetricsTimerGate()

        print("")
        let skipNote = skipped > 0 ? "，跳过 \(skipped) 组" : ""
        print(failures == 0
              ? "═══ AuroraCache 自测：PASS（\(checks) 项\(skipNote)）═══"
              : "═══ AuroraCache 自测：FAIL（\(failures)/\(checks) 项未过）═══")
        return failures
    }

    // MARK: 用例

    private static func testHitAndMiss() {
        print("── ① hit / miss ──")
        let c = AuroraCache<String, Int>(name: "t.hit", capacity: 4)
        var computed = 0
        // ⚠️ 闭包必须写 `() -> Int in`：**多语句闭包不参与泛型结果类型推断**，
        //    写 `{ computed += 1; return 1 }` 会让 Swift 报
        //    "generic parameter 'Value' could not be inferred"。
        //    这不是本类的限制，是 Swift 对多语句闭包的既有行为。
        let a1 = c.value(for: "a") { () -> Int in computed += 1; return 1 }
        let a2 = c.value(for: "a") { () -> Int in computed += 1; return 999 }   // 不该被调用
        ck(a1 == 1 && a2 == 1, "同 key 二次取值命中缓存", "第一次=\(a1) 第二次=\(a2)")
        ck(computed == 1, "compute 只被调用 1 次", "实际 \(computed) 次")
        let m = c.metrics
        ck(m.hits == 1 && m.misses == 1, "指标 hits=1 misses=1", "hits=\(m.hits) misses=\(m.misses)")
        ck(abs(m.hitRate - 0.5) < 1e-9, "命中率 = 50%", String(format: "%.1f%%", m.hitRate * 100))
        ck(m.count == 1, "条目数 = 1", "\(m.count)")
    }

    private static func testEvictionByCapacity() {
        print("── ② 按 capacity 淘汰 ──")
        let c = AuroraCache<Int, Int>(name: "t.cap", capacity: 3)
        for i in 1...5 { _ = c.value(for: i) { i } }
        let m = c.metrics
        ck(m.count == 3, "容量上限 3 生效", "实际 \(m.count)")
        ck(m.evictions == 2, "淘汰 2 条", "实际 \(m.evictions)")
        // LRU 语义：1、2 应被淘汰；3、4、5 应在
        ck(c.peek(1) == nil && c.peek(2) == nil, "最久未用的 1/2 被淘汰")
        ck(c.peek(5) != nil, "最新的 5 仍在")
        // 访问 3 把它提到 MRU，再插一条应淘汰 4
        _ = c.value(for: 3) { 3 }
        _ = c.value(for: 6) { 6 }
        ck(c.peek(3) != nil && c.peek(4) == nil, "访问过的 3 存活、未访问的 4 被淘汰")
    }

    private static func testEvictionByCost() {
        print("── ③ 按 costLimit 淘汰 ──")
        // 每条 100 字节，上限 250 → 最多 2 条
        let c = AuroraCache<Int, Int>(name: "t.cost", capacity: 100,
                                      costLimit: 250, cost: { _ in 100 })
        for i in 1...3 { _ = c.value(for: i) { i } }
        let m = c.metrics
        ck(m.count == 2, "字节上限生效（3 条 → 2 条）", "实际 \(m.count)，bytes=\(m.bytes)")
        ck(m.bytes == 200, "占用字节数正确", "\(m.bytes)")
        ck(m.evictions == 1, "淘汰 1 条", "\(m.evictions)")
    }

    private static func testTTL() {
        print("── ④ TTL 过期 ──")
        let c = AuroraCache<String, Int>(name: "t.ttl", capacity: 4, ttl: 0.15)
        _ = c.value(for: "x") { 7 }
        ck(c.value(for: "x") { 8 } == 7, "TTL 内命中")
        Thread.sleep(forTimeInterval: 0.25)
        let v = c.value(for: "x") { 9 }
        ck(v == 9, "TTL 过后重新计算", "得到 \(v)")
        let m = c.metrics
        ck(m.expirations == 1, "过期计数 = 1", "\(m.expirations)")
    }

    private static func testGeneration() {
        print("── ⑤ generation 换版 ──")
        let c = AuroraCache<String, Int>(name: "t.gen", capacity: 4)
        _ = c.value(for: "k") { 1 }
        ck(c.value(for: "k") { 2 } == 1, "换版前命中旧值")
        ck(c.generation == 0, "初始世代号 = 0", "\(c.generation)")
        c.invalidateGeneration()
        ck(c.generation == 1, "bump 后世代号 = 1", "\(c.generation)")
        let v = c.value(for: "k") { 3 }
        ck(v == 3, "换版后旧条目失效、重新计算", "得到 \(v)")
        ck(c.metrics.generationMisses == 1, "世代失配计数 = 1", "\(c.metrics.generationMisses)")
    }

    private static func testInvalidateWhere() {
        print("── ⑥ invalidate(where:) / invalidateAll() ──")
        let c = AuroraCache<Int, Int>(name: "t.inv", capacity: 10)
        for i in 1...6 { _ = c.value(for: i) { i } }
        c.invalidate { $0 % 2 == 0 }          // 删偶数
        ck(c.metrics.count == 3, "条件失效后剩 3 条", "\(c.metrics.count)")
        ck(c.peek(1) != nil && c.peek(2) == nil, "奇数留下、偶数删掉")
        c.invalidateAll()
        ck(c.metrics.count == 0 && c.metrics.bytes == 0, "invalidateAll 清空且字节归零")
        // 指标是累计量，不该被清空重置
        ck(c.metrics.hits + c.metrics.misses == 6, "指标未被清空重置（累计 6 次查找）",
           "hits+misses=\(c.metrics.hits + c.metrics.misses)")
    }

    private static func testDisabledPassthrough() {
        print("── ⑦ AURORA_CACHE=0 直通 ──")
        // 环境变量在进程启动时读取（AuroraFlags 用 static let），
        // 这里无法在运行中翻转，故只验证"开关读得到、语义可断言"。
        if AuroraCacheSwitch.enabled {
            let c = AuroraCache<String, Int>(name: "t.pass", capacity: 4)
            var n = 0
            _ = c.value(for: "p") { n += 1; return 1 }
            _ = c.value(for: "p") { n += 1; return 2 }
            ck(n == 1, "enabled=true 时缓存生效（compute 1 次）", "\(n) 次")
            print("     · 直通路径需以 `AURORA_CACHE=0 ./AuroraDrive --cache-selftest` 复跑验证")
        } else {
            let c = AuroraCache<String, Int>(name: "t.pass", capacity: 4)
            var n = 0
            _ = c.value(for: "p") { n += 1; return 1 }
            _ = c.value(for: "p") { n += 1; return 2 }
            ck(n == 2, "enabled=false 时直通（compute 2 次）", "\(n) 次")
            ck(c.metrics.count == 0, "直通时不写入缓存", "\(c.metrics.count)")
        }
    }

    /// ⑧ metrics 定时器门禁（2026-10-04，lead 批准的"经验性证明"）
    ///
    /// 【为什么需要这一条】"生产模式零定时器"原来只是代码里的一个 `guard` ——
    ///   那是**论证**不是**证据**。而 `ps -M` 数线程**数不出来**（`DispatchSource`
    ///   用共享全局队列线程池，不新建专属线程；实测生产/测量都是 3 线程，差 0）。
    ///   所以给 `AuroraCache` 加一个只读访问器 `metricsTimerActive`（与项目既有的
    ///   `RoadOverlayCache.lastRenderMs` / `renderCount` / `hitCount` 同类），
    ///   在这里断言 —— 于是这件事变成**可被经验性验证的**，而不是"读代码相信它"。
    private static func testMetricsTimerGate() {
        print("── ⑧ metrics 定时器门禁（生产零定时器）──")
        let probe = AuroraCache<String, Int>(name: "t.timer", capacity: 2)
        let expectActive = PerfBus.enabled
        ck(probe.metricsTimerActive == expectActive,
           "定时器存在性与 PerfBus.enabled 一致",
           "PerfBus.enabled=\(expectActive) metricsTimerActive=\(probe.metricsTimerActive)")
        if expectActive {
            print("     · 当前是测量模式（AURORA_PERF=1）→ 定时器**应当存在** ✓")
            print("     · 生产模式断言请以 `env -u AURORA_PERF ./AuroraDrive --cache-selftest` 复跑")
        } else {
            ck(!probe.metricsTimerActive,
               "**生产模式（AURORA_PERF 未设）下无 metrics 定时器**")
            print("     · 这就是「生产零唤醒」的经验性证明（不依赖读代码）")
        }
    }
}
