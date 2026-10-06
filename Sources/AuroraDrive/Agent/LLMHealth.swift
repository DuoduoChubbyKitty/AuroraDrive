// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  LLMHealth.swift — 多渠道健康监控 + 降级候选链（W3 · 2026-10-06）
// ============================================================================
//
//  【职责边界】
//    本文件**只做决策**：探活、状态记账、候选排序、UI 快照。
//    不做 HTTP 传输（W2 LLMTransport.swift）、不做渠道描述符（W1 LLMBackend.swift）、
//    不碰 UI（W6 AIAgentPanel.swift）。探活用的最小 HTTP 只服务「可达性」判定，
//    必须在 actor 内完成，**绝不碰主线程**，且与 captureQueue / aurora.quest.ocr
//    完全分离（独立 URLSession configuration，互不排队）。
//
//  【实测依据（逐条出处）】
//    · OVH 匿名配额 per IP AND per model，429 可切下一个模型的独立匿名桶：
//      /tmp/vr/dsh-vision-router-main/src/lib/core-primitives.js:1779-1788
//      （原文注释："OVHcloud anonymous quota is per IP AND per model. Keep the free
//        chain ordered largest -> smallest so quality wins first. A 429 on one model
//        can immediately fall through to the next model's independent anonymous bucket."）
//    · OVH 免费层 2 请求/分钟/IP（同上文件 :1780 上方注释）：探活节奏必须极度克制。
//    · FreeTierError / RegionError / ModelDeprecated / 429+Retry-After：W2 实测上游返回。
//    · Zen 免费档 14 个模型仅 space-bunny-free 存活（W1 实测）：健康状态必须按
//      「实测过才敢说健康」记账，不能凭静态清单假定可用。
//
//  【本文件不修改任何其他文件；不内置任何 API Key】
// ============================================================================

import Foundation

// MARK: - 健康状态

/// 单个「渠道 + 模型」的健康态。
///
/// 【为什么是这 7 个】
///   每一个都对应一种**处置方式不同**的上游失败（出处见 AgentSettings 与 W2 实测）：
///   冷却时长、是否换模型、是否只影响本会话，全都不同 —— 合并成一个 `failed` 会丢信息。
enum ModelHealth: String, Codable, Sendable {
    /// 尚未探活过（冷启动前 / 大目录里未排到的模型）。
    case unknown
    /// 最近一次判定为可用。
    case ok
    /// 上游免费层门禁（实测 `{"type":"error","error":{"type":"FreeTierError"}}`）。
    /// 处置：冷却 600s（容量池可能恢复），不算「模型不存在」。
    case gated
    /// 区域封锁（实测 `RegionError`）。处置：**本会话永久**（换网络才会变）。
    case regionBlocked
    /// 模型已下线（实测 `ModelDeprecated`，可能带 metadata.replacement）。
    /// 处置：切 replacement；无 replacement 等同失效。
    case deprecated
    /// 限流（实测 429，含 Retry-After 头）。处置：按 retryAfter 冷却，
    /// **OVH 特例**：立刻切下一个模型的独立匿名桶（配额 per model）。
    case rateLimited
    /// 永久失效（HTTP 404 / model not found）。重探无意义。
    case dead

    /// 是否可作为候选（`unknown` 允许：冷启动未探到不该等于不可用；
    /// 真不可用会在第一次真实请求里被 noteFailure 立刻改判）。
    var isSelectable: Bool {
        switch self {
        case .ok, .unknown: return true
        case .gated, .regionBlocked, .deprecated, .rateLimited, .dead: return false
        }
    }

    /// 是否属于「已被证明坏掉」的状态（用于探活时避免把已知坏状态洗白）。
    var isKnownBad: Bool {
        switch self {
        case .gated, .regionBlocked, .deprecated, .dead: return true
        case .ok, .unknown, .rateLimited: return false
        }
    }

    /// 候选链里的**排序层级**（越小越先被尝试）。
    ///
    /// 【为什么必须有这一层】2026-10-06 联调实测：`buildChain` 原先只按
    /// 「用户选定 → 同渠道 → 跨渠道」排，**完全不看健康度**。结果是配置渠道
    /// （默认 OVH）一方 5 个已判 rateLimited 的模型霸占前 4 名，而**探活真的
    /// 是 ok 的 pollinationsLegacy / zenFree 被挤出尝试窗口**（消费端只试 4 个，
    /// 见 AgentChatService.reply 与 LLMSelfTest.networkRealRequest）——
    /// A1「对话真能用」因此直接失败。
    /// 排序必须让**已知可用的**先上，其次才是**还没试过的**，最后才是**已知坏的**。
    var chainTier: Int {
        switch self {
        case .ok:            return 0   // 实测可达：最优
        case .unknown:       return 1   // 没探过：仍是合法候选，但不能插队到已知可用之前
        case .rateLimited:   return 2   // 限流：可能很快恢复，排在已知可用之后仍值得试
        case .gated:         return 3   // 门禁：冷却较久
        case .deprecated:    return 4   // 已下线：等 replacement
        case .dead:          return 5   // 永久失效：只比被剔除好一点
        case .regionBlocked: return 6   // 本会话永久：最后
        }
    }

    /// UI 展示用语。
    var displayName: String {
        switch self {
        case .unknown:       return "未探测"
        case .ok:            return "正常"
        case .gated:         return "免费层受限"
        case .regionBlocked: return "区域受限"
        case .deprecated:    return "已下线"
        case .rateLimited:   return "限流中"
        case .dead:          return "不可用"
        }
    }
}

// MARK: - 候选（渠道 + 模型）

/// 降级链上的一个候选项。**这是 W6 聊天路径与 W7 AgentLoop 的唯一输入。**
struct LLMCandidate: Sendable, Hashable, Codable {
    var backend: LLMBackendKind
    var model: String
    var supportsVision: Bool
    var supportsTools: Bool
    var isFree: Bool
    /// 上下文长度（排序用：同渠道内短上下文靠后）。W1 的 LLMModelInfo 可能为 nil。
    var contextLength: Int?

    /// 全局唯一键（状态、冷却、缓存都以它为 key）。
    var key: String { "\(backend.rawValue)/\(model)" }

    init(backend: LLMBackendKind, model: String, supportsVision: Bool,
         supportsTools: Bool, isFree: Bool, contextLength: Int? = nil) {
        self.backend = backend
        self.model = model
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.isFree = isFree
        self.contextLength = contextLength
    }

    /// 从 W1 的模型元数据构造。
    /// isFree 取「元数据声明免费」或「渠道本身免 key」——两者任一为真即对用户免费。
    init(_ info: LLMModelInfo, backend: LLMBackendKind) {
        self.init(backend: backend,
                  model: info.id,
                  supportsVision: info.supportsVision,
                  supportsTools: info.supportsTools,
                  isFree: info.isFree || backend.isKeyless,
                  contextLength: info.contextLength)
    }
}

// MARK: - UI 快照

/// UI 底部小字的数据源（W6 用）。全部字段都是**只读事实**，不含推测。
struct LLMHealthSnapshot: Sendable, Equatable {
    var healthyCount: Int
    var totalCount: Int
    var backend: LLMBackendKind?
    var backendDisplayName: String
    var model: String
    /// 最近一次真实请求的延迟（毫秒）。
    var latencyMs: Double?
    /// 是否正在降级中（当前候选 ≠ 用户选定）。
    var degraded: Bool
    var degradedReason: String?
    /// 最近一次失败原因（tooltip 用，如实展示上游原话）。
    var lastErrorReason: String?
    var isProbing: Bool
    /// 完整候选链预览（hover tooltip 用）。
    var chainPreview: [String]
    var isFreeTier: Bool
    /// 生效的探活间隔（AURORA_LLM_PROBE_INTERVAL 覆盖后的值）。
    var probeIntervalSeconds: TimeInterval
    /// 用户是否开启了「📷 带截图」（来自 `AgentSettings.visionEnabled`）。
    ///
    /// 【为什么小字需要它】用户 2026-10-06 指出：小字显示 `ovh · Qwen3.5-9B`，
    /// 而那是**纯文本**模型——一旦打开视觉开关，链路会换成视觉候选，
    /// 小字若仍显示纯文本模型，看起来就像"拿纯文本模型看图"。故小字必须
    /// 按**当前实际会用的链路**推导并显式标注视觉状态。
    var visionRequired: Bool = false
    /// 视觉候选链里是否存在真正带视觉的模型（`visionRequired` 为真时有意义）。
    var visionModelAvailable: Bool = false

    /// 直接可用的单行文案（W6 也可以自己拼，这里给一份与规格一致的默认实现）：
    ///   · 免 key：`免费档 · ovh · Qwen2.5-VL-72B · 健康 4/7 · 0.9s`
    ///   · 降级中：`⚠️ 已降级 → OpenCode Zen · space-bunny-free`
    ///   · 自备 key：`智谱 GLM · glm-4.6v-flash · 正常`
    ///   · 待首次请求：`免费档 · 健康 3/13 · 待首次请求`
    ///   · 全挂：`⚠️ 无可用模型（点此诊断）`
    ///
    /// 【兜底文案必须与事实一致 —— 2026-10-06 实测修复】
    ///   原实现只判断 `!model.isEmpty`，于是"有健康模型但当前没推导出候选"
    ///   （`--llm-probe` 从不调 candidates() 的场景）会误报"无可用模型"。
    ///   小字是用户唯一的状态窗口：把"暂时没取到候选"说成"整个 AI 挂了"，
    ///   会让用户白白去查配置。**只有 `healthyCount == 0` 才允许说无可用模型。**
    var displayLine: String {
        // ① 一个健康的都没有 → 才是真的"无可用模型"
        if totalCount == 0 || (healthyCount == 0 && model.isEmpty) {
            return "⚠️ 无可用模型（点此诊断）"
        }
        // ①' 开了视觉但没有任何视觉候选 → 如实说，不假装（用户规格：不静默降级）
        if visionRequired && !visionModelAvailable {
            return "⚠️ 无可用视觉模型（关掉 📷 或配置 API Key）"
        }
        // ② 有健康模型但当前没推导出候选（未取链/全在冷却）→ 如实说"待首次请求"
        if model.isEmpty {
            return "免费档 · 健康 \(healthyCount)/\(totalCount) · 待首次请求"
        }
        // ③ 视觉模式：标注 👁，让用户一眼看出"当前用的是视觉模型"
        let visionTag = visionRequired ? "👁 " : ""
        if degraded { return "\(visionTag)⚠️ 已降级 → \(backendDisplayName) · \(model)" }
        if !isFreeTier { return "\(visionTag)\(backendDisplayName) · \(model) · 正常" }
        let latency = latencyMs.map { String(format: "%.1fs", $0 / 1000) } ?? "--"
        let short = LLMHealthSnapshot.shortName(backend)
        return "\(visionTag)免费档 · \(short) · \(model) · 健康 \(healthyCount)/\(totalCount) · \(latency)"
    }

    static func shortName(_ kind: LLMBackendKind?) -> String {
        guard let kind else { return "未定" }
        switch kind {
        case .ovhAnonymous:       return "ovh"
        case .zenFree:            return "zen"
        case .pollinations:       return "pollinations"
        case .pollinationsLegacy: return "pollinations-legacy"
        case .zhipu:              return "zhipu"
        case .groq:               return "groq"
        case .openRouter:         return "openrouter"
        case .userKey:            return "custom"
        }
    }
}

// MARK: - 自检结果（供 W8 离线断言）

/// 纯逻辑自检结果。**不修改任何状态**，可安全反复调用。
struct LLMHealthSelfCheck: Sendable, Equatable {
    var ok: Bool
    var checks: [String]
    var failures: [String]
}

// MARK: - 上游信号分类（纯函数，便于离线单测）

/// 一次探活观察到的上游信号。与 `LLMErrorKind` 同构但**独立**：
/// 探活不经过 W2 的传输层，只做可达性判定，所以在这里自带一份最小分类。
enum LLMProbeSignal: Sendable, Equatable {
    case healthy
    case freeTier
    case region
    case rateLimited(retryAfter: TimeInterval?)
    case deprecated(replacement: String?)
    case notFound
    case keyInvalid
    case serverError(Int)
    case transport(String)

    /// 映射到健康态。`transport` → `.unknown`：**网络问题不是模型问题**，
    /// 不能因为本机断网就把全部模型判死（否则降级链会清空并误导用户）。
    var health: ModelHealth {
        switch self {
        case .healthy:      return .ok
        case .freeTier:     return .gated
        case .region:       return .regionBlocked
        case .rateLimited:  return .rateLimited
        case .deprecated:   return .deprecated
        case .notFound:     return .dead
        case .keyInvalid:   return .unknown
        case .serverError:  return .unknown
        case .transport:    return .unknown
        }
    }

    var replacement: String? {
        if case .deprecated(let r) = self { return r }
        return nil
    }

    var reasonText: String {
        switch self {
        case .healthy:               return "可达"
        case .freeTier:              return "免费层门禁（FreeTierError）"
        case .region:                return "区域封锁（RegionError）"
        case .rateLimited(let ra):   return ra.map { "限流 429（Retry-After \(Int($0))s）" } ?? "限流 429"
        case .deprecated(let rep):   return rep.map { "模型已下线 → 改用 \($0)" } ?? "模型已下线（无替代）"
        case .notFound:              return "模型不存在（404 / model not found）"
        case .keyInvalid:            return "API Key 无效（配置问题，非模型问题）"
        case .serverError(let code): return "上游 \(code)（瞬时故障）"
        case .transport(let msg):    return "网络不可达：\(msg)"
        }
    }
}

// MARK: - 健康监控（actor 单例）

/// 多渠道健康监控 + 降级候选链。
///
/// 【设计红线】
///   1. 所有状态与网络都在 actor 内 / 非隔离静态函数里，**绝不碰主线程**。
///   2. 探活节奏自适应：冷启动扫一轮 → 对话中不周期探活 → 空闲 60s 单探当前模型。
///   3. 冷却态（熔断、429）**不落盘**，重启即清 —— 避免把一次临时限流写成永久判死。
actor LLMHealthMonitor {

    static let shared = LLMHealthMonitor()

    // MARK: 常量（可调参数与理由）

    /// 空闲探活间隔（秒）。环境变量 `AURORA_LLM_PROBE_INTERVAL` 可覆盖。
    ///
    /// 【为什么默认 60 而不是 1 —— 本文件最重要的一条注释】
    ///   "37 模型 × 1/s 会把免费档打死"：Pollinations 一家就有 37 个模型，
    ///   加上 OVH 5 + Zen 1 + legacy 1 ≈ 44 个候选。若按 1 秒一轮全量扫，
    ///   就是 44 req/s 打向**别人的免费公共容量池**，后果有三：
    ///     ① 我们自己立刻被限流（OVH 匿名实测仅 2 请求/分钟/IP/模型，
    ///        出处 dsh-vision-router/src/lib/core-primitives.js:1780 上方注释）；
    ///     ② 把"被限流"误判成"模型坏了" → 触发错误降级，用户看到假故障；
    ///     ③ 挤占其他用户配额（免费档是公共资源，这么用不体面也不可持续）。
    ///   所以 60s 只单探**当前模型**（1 req/min），全量扫描只在冷启动与
    ///   失效后触发，且带 20s 去抖 + 3 并发。
    ///   低于 5s 的覆盖值一律忽略（防手滑，包括环境变量）。
    private static let defaultProbeInterval: TimeInterval = 60
    private static let minimumProbeInterval: TimeInterval = 5

    /// 全量探活并发上限（3）：既不让免费档瞬间过载，也不让冷启动拖太久。
    private static let probeConcurrency = 3
    /// 单个探活请求硬超时（8s）。超时按「未知」处理，不判死。
    private static let probeTimeoutSeconds: TimeInterval = 8
    /// 失效后立即全量重探的去抖窗口（20s）：失败风暴时避免探活自我打转。
    private static let reprobeDebounce: TimeInterval = 20
    /// 大目录（Pollinations 37 个）在**全量探活**中最多探几个。
    /// 其余保持 unknown，等真实请求「顺路探活」——这是免费档保护，不是偷懒。
    private static let largeCatalogProbeBudget = 6
    /// 磁盘缓存最长保留 7 天（超期视为过期，重新冷启动扫描）。
    private static let diskCacheMaxAge: TimeInterval = 7 * 24 * 3600

    /// 熔断：同一模型连续失败 3 次 → 冷却 300s。
    private static let circuitBreakerThreshold = 3
    private static let circuitBreakerCooldown: TimeInterval = 300
    /// 门禁（gated）冷却：600s。
    private static let gatedCooldown: TimeInterval = 600

    /// 健康缓存 TTL（秒）。磁盘与内存共用同一套 TTL 语义。
    private static func ttl(for health: ModelHealth) -> TimeInterval {
        switch health {
        case .ok:            return 60
        case .unknown:       return 0
        case .rateLimited:   return 20
        case .gated:         return gatedCooldown
        // 以下三种在**本会话内**都是终态：
        //   regionBlocked / dead / deprecated（无替代）——重探是纯浪费配额。
        //   注意：磁盘缓存会剔除 regionBlocked，见 persistPayload()。
        case .regionBlocked: return .greatestFiniteMagnitude
        case .deprecated:    return .greatestFiniteMagnitude
        case .dead:          return .greatestFiniteMagnitude
        }
    }

    // MARK: 内存状态

    /// 单条健康记录（内存态，可落盘部分见 DiskEntry）。
    struct HealthRecord: Sendable {
        var health: ModelHealth = .unknown
        var checkedAt: Date = .distantPast
        var lastSuccessAt: Date?
        var latencyMs: Double?
        var replacementModel: String?
        var contextLength: Int?
        var reason: String?
    }

    private var records: [String: HealthRecord] = [:]
    /// 连续失败计数（熔断用）。成功即清零。
    private var consecutiveFailures: [String: Int] = [:]
    /// 冷却截止时间。**不落盘**（重启即清）。
    private var cooldownUntil: [String: Date] = [:]
    /// OVH 轮转游标（不落盘）。指向静态表中当前应优先使用的模型下标。
    private var ovhRotationCursor: Int = 0
    /// 上一次全量探活开始时间（去抖用）。
    private var lastFullProbeAt: Date = .distantPast
    /// 上一次空闲单探时间（节流用；对话中不探，只由 probeCurrentIfIdle 驱动）。
    private var lastIdleProbeAt: Date = .distantPast
    /// 最近一次真实请求（成功或失败）时间。用于判定"对话中"→ 空闲节拍跳过探活。
    private var lastActivityAt: Date = .distantPast
    /// 空闲探活循环（startAdaptiveProbing 启动；幂等）。
    private var idleProbeTask: Task<Void, Never>?
    /// 冷启动是否已经扫过（防止 candidates() 反复触发）。
    private var coldStartTriggered = false
    private var isProbing = false
    private var probeTask: Task<Void, Never>?
    /// 最近一次 candidates() 选中的「当前候选」。
    private var lastCurrent: LLMCandidate?
    private var lastChain: [LLMCandidate] = []
    private var lastDegradedReason: String?
    private var lastErrorReason: String?
    private var lastLatencyMs: Double?
    /// 本会话重置前是否发生过降级（供 UI 显示"降级中"）。
    private var degradedSince: Date?

    // 配置缓存（避免每次候选聚合都读 UserDefaults / 小本本文件）
    private var settingsCache: AgentSettings?
    private var settingsCachedAt: Date = .distantPast
    private static let settingsCacheTTL: TimeInterval = 2

    /// 生效的探活间隔（环境变量优先，带下限保护）。
    let probeInterval: TimeInterval

    // MARK: 初始化

    private init() {
        // 环境变量覆盖（<5s 忽略：见 defaultProbeInterval 注释）
        let env = ProcessInfo.processInfo.environment["AURORA_LLM_PROBE_INTERVAL"]
        var interval = LLMHealthMonitor.defaultProbeInterval
        if let raw = env, let value = Double(raw) {
            if value >= LLMHealthMonitor.minimumProbeInterval {
                interval = value
            } else {
                NSLog("[LLMHealth] 忽略 AURORA_LLM_PROBE_INTERVAL=\(raw)："
                      + "低于 \(LLMHealthMonitor.minimumProbeInterval)s 会打死免费档配额")
            }
        }
        self.probeInterval = interval
        // 冷启动读磁盘缓存（同步、极小 JSON；不碰主线程之外的东西）
        let loaded = LLMHealthMonitor.loadDiskRecords()
        self.records = loaded
    }

    // MARK: - 1. 探活

    /// 全量探活（自适应）。
    ///
    /// 调用时机（**只有这三种**）：
    ///   · 冷启动一次（扫描结果落盘）
    ///   · 真实请求发现当前模型失效（20s 去抖后立即重扫）
    ///   · 空闲 60s 的单探发现当前模型失效
    /// **对话进行中不做周期探活** —— 真实请求本身就是探活（见 noteSuccess/noteFailure）。
    ///
    /// - Parameters:
    ///   - force: true 时忽略缓存新鲜度，全部重探。
    ///   - includeWholeCatalog: true 时连 Pollinations 的 37 个模型也全探（默认 false，
    ///     只探预算内的前若干个；其余留 unknown 走"顺路探活"）。
    /// - Returns: `候选键 -> 健康态`（键格式 `backend/model`）。
    @discardableResult
    func probeAll(force: Bool = false, includeWholeCatalog: Bool = false) async -> [String: ModelHealth] {
        if isProbing { return records.mapValues(\.health) }
        isProbing = true
        lastFullProbeAt = Date()
        defer { isProbing = false }

        let targets = probeTargets(force: force, includeWholeCatalog: includeWholeCatalog)
        guard !targets.isEmpty else {
            await LLMHealthMonitor.persist(records: records)
            return records.mapValues(\.health)
        }

        let settingsNow = cachedSettings()
        let apiKey = settingsNow.apiKey
        // .userKey 的端点来自用户配置；其余渠道传 nil（W1 会用渠道自身的静态端点）
        let userOverride: String? = settingsNow.baseUrl.isEmpty ? nil : settingsNow.baseUrl
        let timeout = LLMHealthMonitor.probeTimeoutSeconds
        let concurrency = LLMHealthMonitor.probeConcurrency
        var result: [String: ModelHealth] = [:]

        // 【并发上限 3 + 整轮可达上界】
        // 滑窗保证同时最多 3 个在飞；**不需要额外的整轮看门狗**，因为每一跳
        // 都被 URLSession 双重封顶（request 8s / resource 10s，且
        // waitsForConnectivity=false），所以整轮 ≤ 10s × ⌈n/3⌉，必然收敛。
        // 子任务里的网络是 nonisolated 静态函数，跑在并发执行器上；
        // actor 只在槽位归队时短暂介入（applyProbe），不会长时间独占。
        await withTaskGroup(of: (LLMCandidate, LLMProbeSignal, Double).self) { group in
            var iterator = targets.makeIterator()
            var inFlight = 0
            while inFlight < concurrency, let candidate = iterator.next() {
                group.addTask {
                    let outcome = await LLMHealthMonitor.probeOnce(
                        candidate, apiKey: apiKey, timeout: timeout,
                        baseURLOverride: candidate.backend == .userKey ? userOverride : nil)
                    return (candidate, outcome.signal, outcome.latencyMs)
                }
                inFlight += 1
            }
            while let (candidate, signal, latency) = await group.next() {
                applyProbe(signal, latencyMs: latency, to: candidate)
                result[candidate.key] = effectiveHealth(candidate)
                if let next = iterator.next() {
                    group.addTask {
                        let outcome = await LLMHealthMonitor.probeOnce(
                            next, apiKey: apiKey, timeout: timeout,
                            baseURLOverride: next.backend == .userKey ? userOverride : nil)
                        return (next, outcome.signal, outcome.latencyMs)
                    }
                }
            }
        }

        await LLMHealthMonitor.persist(records: records)
        return result
    }

    /// 启动自适应探活循环（**幂等**，W6 在面板出现时调用一次即可）。
    ///
    /// 三条轨道（严格照计划，不多探一次）：
    ///   · 冷启动：立刻扫一轮全量并落盘（结果进内存 + llm-health-cache.json）
    ///   · 对话中：**不周期探活** —— 真实请求即探活（noteSuccess/noteFailure），
    ///     本条轨道靠 `lastActivityAt` 判定并整拍跳过
    ///   · 空闲：每 `probeInterval`（默认 60s）**单探当前模型**，失效则立即全量重探
    ///
    /// 循环体跑在 actor 内，网络用独立 URLSession —— 与 captureQueue /
    /// aurora.quest.ocr 无任何共享资源，不会互相排队。
    func startAdaptiveProbing() {
        guard idleProbeTask == nil else { return }
        coldStartTriggered = true
        idleProbeTask = Task { [weak self] in
            guard let self else { return }
            // 冷启动：扫一轮 + 落盘（probeAll 内部已完成落盘）
            await self.probeAll(force: false)
            while !Task.isCancelled {
                let interval = self.probeInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                // 对话中不探活（真实请求已经在刷新状态）
                let idleFor = await self.idleSeconds()
                if idleFor < interval { continue }
                await self.probeCurrentIfIdle(force: false)
            }
        }
    }

    /// 停止探活循环（面板关闭 / 进程退出前调用）。
    func stopAdaptiveProbing() {
        idleProbeTask?.cancel()
        idleProbeTask = nil
    }

    private func idleSeconds() -> TimeInterval {
        Date().timeIntervalSince(lastActivityAt == .distantPast ? lastIdleProbeAt : lastActivityAt)
    }

    /// 冷启动补扫：候选聚合第一次被调用时若从未扫过，后台补一轮。
    /// （不阻塞本次 candidates 返回：先把静态链给出去，扫完下一轮自然更准。）
    ///
    /// 【为什么必须探测 `probeCurrentIfIdle` 的节流】这段逻辑挂在 `candidates()`
    /// 上，而 `candidates()` 被 W8 的离线自检反复调用。若不加节流，**一次
    /// 本该"不发任何请求"的离线自检也会把整条免费档链扫一遍**——
    /// 既浪费配额，又让自检静默依赖网络（实测就是被这条咬到的：
    /// selfCheck() 声称"不改状态、不联网"，却通过 candidates() 触发了全量探活，
    /// 一轮下来耗时 3 分钟以上）。冷启动一轮在本进程内只做一次，
    /// 且受 idle 节拍约束。
    private func triggerColdStartIfNeeded() {
        guard !coldStartTriggered else { return }
        coldStartTriggered = true
        // 已经建过实时活动（真实请求）就不需要额外冷扫：真实请求本身就是探活
        guard lastActivityAt == .distantPast else { return }
        guard Date().timeIntervalSince(lastIdleProbeAt) >= probeInterval else { return }
        lastIdleProbeAt = Date()
        Task { [weak self] in await self?.probeAll(force: false) }
    }

    /// 立刻做一次冷启动扫描（W6 面板出现时调用）。
    /// 与 `triggerColdStartIfNeeded` 的区别：**不受 idle 节拍约束**，
    /// 但仍保证一个进程只扫一次，且正在扫时不重入。
    func coldStartProbeIfNeeded() async {
        guard !coldStartTriggered else { return }
        coldStartTriggered = true
        lastIdleProbeAt = Date()
        await probeAll(force: false)
    }

    /// **空闲单探**：每 `probeInterval` 秒最多探一次**当前模型**（不扫全量）。
    ///
    /// 这是「对话中不周期探活」与「冷启动全量扫描」之间的第三条轨道：
    /// 面板挂着不动时用 1 req/60s 维持对当前模型的判断，开销是全量扫描的
    /// 1/44（44 个候选），既不让免费档掉配额，也不至于状态发霉。
    /// 由 W6 在空闲定时器里调用（**不在主线程做网络**，只 await 本 actor）。
    ///
    /// - Returns: 探活后当前模型的健康态；无当前候选时返回 nil。
    @discardableResult
    func probeCurrentIfIdle(force: Bool = false) async -> ModelHealth? {
        let now = Date()
        if !force, now.timeIntervalSince(lastIdleProbeAt) < probeInterval { return lastCurrent.map { effectiveHealth($0) } }

        let settings = cachedSettings()
        let model = lastCurrent?.model ?? resolvedModel(for: settings.backendKind, settings: settings)
        guard !model.isEmpty else { return nil }
        guard let target = candidate(for: settings.backendKind, model: model, settings: settings, now: now) else { return nil }
        if !force, isFresh(records[target.key], now: now) { return effectiveHealth(target) }

        lastIdleProbeAt = now
        let outcome = await LLMHealthMonitor.probeOnce(
            target, apiKey: settings.apiKey,
            timeout: LLMHealthMonitor.probeTimeoutSeconds,
            baseURLOverride: target.backend == .userKey ? settings.baseUrl : nil)
        applyProbe(outcome.signal, latencyMs: outcome.latencyMs, to: target)
        // 单探发现失效 → 立即全量重探（requestReprobe 自带 20s 去抖）
        if !effectiveHealth(target).isSelectable {
            requestReprobe(reason: "空闲单探失效 \(target.key)")
        }
        await LLMHealthMonitor.persist(records: records)
        return effectiveHealth(target)
    }

    /// 失效后立即全量重探（带 20s 去抖）。由 noteFailure 在判定失效时调用。
    func requestReprobe(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastFullProbeAt) >= LLMHealthMonitor.reprobeDebounce else { return }
        guard probeTask == nil else { return }
        lastFullProbeAt = now
        NSLog("[LLMHealth] 触发全量重探：\(reason)")
        probeTask = Task { [weak self] in
            await self?.probeAll(force: false)
            await self?.finishProbeTask()
        }
    }

    private func finishProbeTask() { probeTask = nil }

    /// 生成全量探活目标（按渠道链顺序，跳过新鲜缓存）。
    private func probeTargets(force: Bool, includeWholeCatalog: Bool) -> [LLMCandidate] {
        let settings = cachedSettings()
        let now = Date()
        var out: [LLMCandidate] = []
        var seen = Set<String>()
        for backend in settings.effectiveBackends {
            var list = staticCandidates(for: backend, settings: settings)
            if !includeWholeCatalog, list.count > LLMHealthMonitor.largeCatalogProbeBudget {
                list = Array(list.prefix(LLMHealthMonitor.largeCatalogProbeBudget))
            }
            for candidate in list {
                guard !seen.contains(candidate.key) else { continue }
                seen.insert(candidate.key)
                if force || !isFresh(records[candidate.key], now: now) {
                    out.append(candidate)
                }
            }
        }
        return out
    }

    /// 缓存是否仍新鲜（按健康态决定 TTL；见 ttl(for:)）。
    private func isFresh(_ record: HealthRecord?, now: Date) -> Bool {
        guard let record, record.health != .unknown else { return false }
        let age = now.timeIntervalSince(record.checkedAt)
        return age < LLMHealthMonitor.ttl(for: record.health)
    }

    /// 把探活结果写回状态。规则：
    ///   · 已知坏状态不因一次「网络不可达/上游 5xx」被洗白（避免误报健康）。
    ///   · 探到坏状态一律覆盖（新证据优于旧结论）。
    private func applyProbe(_ signal: LLMProbeSignal, latencyMs: Double, to candidate: LLMCandidate) {
        var record = records[candidate.key] ?? HealthRecord()
        let health = signal.health
        let now = Date()

        if health == .unknown, record.health.isKnownBad {
            // 保持原判（只更新时间戳，避免立刻重复探测）
            record.checkedAt = now
            record.reason = signal.reasonText
            records[candidate.key] = record
            return
        }

        record.health = health
        record.checkedAt = now
        record.reason = signal.reasonText
        record.replacementModel = signal.replacement
        if health == .ok {
            record.lastSuccessAt = now
            record.latencyMs = latencyMs
            consecutiveFailures[candidate.key] = 0
            cooldownUntil[candidate.key] = nil
            if candidate.backend == .ovhAnonymous { stickyOVHCursor(to: candidate) }
        }
        records[candidate.key] = record
    }

    // MARK: - 2. 真实请求反馈（对话中唯一的"探活"）

    /// 真实请求成功 → 立刻刷新为健康（这是最可信的探活证据）。
    func noteSuccess(_ candidate: LLMCandidate, latencyMs: Double) {
        var record = records[candidate.key] ?? HealthRecord()
        let now = Date()
        lastActivityAt = now
        record.health = .ok
        record.checkedAt = now
        record.lastSuccessAt = now
        record.latencyMs = latencyMs
        record.reason = nil
        record.replacementModel = nil
        records[candidate.key] = record
        consecutiveFailures[candidate.key] = 0
        cooldownUntil[candidate.key] = nil
        lastLatencyMs = latencyMs
        lastErrorReason = nil
        if candidate.backend == .ovhAnonymous { stickyOVHCursor(to: candidate) }
    }

    /// 真实请求失败 → 按错误种类更新状态（**错误驱动状态机**，出处见各分支注释）。
    ///
    /// 与 `LLMErrorKind` 的对应关系逐条来自 W2 实测上游返回；本函数对
    /// `LLMError` 只做 `as?` 鸭子判定，拿不到就按普通失败（仅累计熔断计数），
    /// 不会误伤状态。
    func noteFailure(_ candidate: LLMCandidate, error: Error) {
        let now = Date()
        var record = records[candidate.key] ?? HealthRecord()
        lastErrorReason = nil

        // Task.cancel（用户切页/取消）不是模型问题：不清零、不计数、不改状态。
        if error is CancellationError { return }

        // 有任何真实请求活动 → 空闲节拍让位（对话中不做周期探活）
        lastActivityAt = now

        if let llmError = error as? LLMError {
            switch llmError.kind {
            case .invalidKey:
                // ── 分两种情况，别一律当"配置问题" ──
                // ① 需 key 渠道：确实是用户配置问题（key 错/过期），
                //    **不改模型状态**（否则配错 key 会把整条链判死，
                //    用户改好 key 也看不到恢复）。
                // ② 免 key 渠道却回 401：**不是配置问题，是渠道对匿名调用关门了**。
                //    实测出处（W1 反馈）：gen.pollinations.ai 的 chat 端点当前
                //    401 要 key，而 GET /v1/models 仍 200 —— 即"模型清单拿得到、
                //    聊天用不了"。这种情况必须判为门禁并冷却，否则该渠道会被
                //    反复选中、反复 401，用户看到的是"一直卡着不回话"。
                if candidate.backend.requiresKey {
                    lastErrorReason = "API Key 无效：\(llmError.message)"
                    return
                }
                record.health = .gated
                record.checkedAt = now
                record.reason = "匿名调用被拒（401，渠道转为需 key）"
                records[candidate.key] = record
                cooldownUntil[candidate.key] = now.addingTimeInterval(LLMHealthMonitor.gatedCooldown)
                lastErrorReason = "\(candidate.backend.displayName) 匿名调用被拒（401）"
                requestReprobe(reason: "anonymous-401 \(candidate.key)")
                return

            case .cancelled:
                return

            case .gated:
                // 免费层门禁：冷却 600s（容量池可能恢复），不算永久失效。
                record.health = .gated
                record.checkedAt = now
                record.reason = "免费层门禁"
                records[candidate.key] = record
                cooldownUntil[candidate.key] = now.addingTimeInterval(LLMHealthMonitor.gatedCooldown)
                lastErrorReason = "免费层受限（\(candidate.model)）"
                requestReprobe(reason: "gated \(candidate.key)")
                return

            case .regionBlocked:
                // 本会话永久：换网络才会变，重探纯浪费配额。
                record.health = .regionBlocked
                record.checkedAt = now
                record.reason = "区域封锁"
                records[candidate.key] = record
                cooldownUntil[candidate.key] = nil   // 终态，无需冷却表
                lastErrorReason = "区域受限（\(candidate.model)）"
                requestReprobe(reason: "regionBlocked \(candidate.key)")
                return

            case .modelDeprecated:
                // 切 replacement：把替代模型写进记录，candidates() 会把它排到最前。
                record.health = .deprecated
                record.checkedAt = now
                record.replacementModel = llmError.replacementModel
                record.reason = llmError.replacementModel.map { "已下线 → \($0)" } ?? "已下线（无替代）"
                records[candidate.key] = record
                lastErrorReason = record.reason
                // 替代模型若已知则立刻纳入（写一条 unknown 记录，让它进入候选池）
                if let replacement = llmError.replacementModel, !replacement.isEmpty {
                    let key = "\(candidate.backend.rawValue)/\(replacement)"
                    if records[key] == nil {
                        records[key] = HealthRecord(health: .unknown, checkedAt: now,
                                                    reason: "由 \(candidate.model) 替代而来")
                    }
                }
                requestReprobe(reason: "deprecated \(candidate.key)")
                return

            case .modelNotFound:
                // 永久失效：重探无意义（模型名就是错的）。
                record.health = .dead
                record.checkedAt = now
                record.reason = "模型不存在"
                records[candidate.key] = record
                lastErrorReason = "模型不存在（\(candidate.model)）"
                return

            case .rateLimited:
                let retryAfter = llmError.retryAfter
                record.health = .rateLimited
                record.checkedAt = now
                record.reason = retryAfter.map { "限流，\(Int($0))s 后可试" } ?? "限流"
                records[candidate.key] = record
                let wait = max(retryAfter ?? 0, LLMHealthMonitor.ttl(for: .rateLimited))
                cooldownUntil[candidate.key] = now.addingTimeInterval(wait)
                lastErrorReason = "限流（\(candidate.model)）"

                // 【OVH 特例】per IP AND per model 的独立匿名桶：
                // 429 立刻轮转下一个模型，而不是等冷却（出处 core-primitives.js:1780-1782）。
                if candidate.backend == .ovhAnonymous {
                    advanceOVHRotation(reason: "429 on \(candidate.model)")
                } else {
                    requestReprobe(reason: "rateLimited \(candidate.key)")
                }
                return

            case .timeout, .network, .upstream, .badResponse, .missingKey:
                // 瞬时/传输类：计入熔断，但不改健康态（网络问题不是模型问题）。
                // badResponse（200 但空 content）也走这里：连续 3 次才熔断。
                lastErrorReason = "\(llmError.kind): \(llmError.message)"
                registerTransientFailure(candidate, now: now, reason: lastErrorReason ?? "")
                return
            }
        }

        lastErrorReason = "\(error)"
        registerTransientFailure(candidate, now: now, reason: lastErrorReason ?? "")
    }

    /// 连续失败累计 → 3 次熔断（冷却 300s，落进冷却表而非模型状态）。
    private func registerTransientFailure(_ candidate: LLMCandidate, now: Date, reason: String) {
        let streak = (consecutiveFailures[candidate.key] ?? 0) + 1
        consecutiveFailures[candidate.key] = streak
        if streak >= LLMHealthMonitor.circuitBreakerThreshold {
            cooldownUntil[candidate.key] = now.addingTimeInterval(LLMHealthMonitor.circuitBreakerCooldown)
            consecutiveFailures[candidate.key] = 0
            NSLog("[LLMHealth] 熔断 \(candidate.key)：连续 \(streak) 次失败（\(reason)），冷却 \(Int(LLMHealthMonitor.circuitBreakerCooldown))s")
            requestReprobe(reason: "circuit-open \(candidate.key)")
        }
    }

    // MARK: - 3. 候选聚合

    /// 跨渠道候选聚合（降级链）。
    ///
    /// 顺序（严格照计划）：
    ///   ① 用户选定模型（含 deprecated 的 replacement 优先）
    ///   ② 同渠道其他健康模型（上次成功时间 ↓，上下文长度 ↓）
    ///   ③ 跨渠道：ovhAnonymous → zenFree → pollinations → pollinationsLegacy
    ///               → zhipu → groq → openRouter（= LLMBackendKind.allCases 顺序）
    ///   ④ requireVision / requireTools 过滤
    ///   ⑤ 全链失败返回空数组（**绝不编造候选**）
    ///
    /// - Note: `fallbackEnabled == false` 时只返回用户选定那一个（可能为空）。
    func candidates(preferred: String? = nil,
                    requireVision: Bool = false,
                    requireTools: Bool = false) async -> [LLMCandidate] {
        triggerColdStartIfNeeded()
        let settings = cachedSettings()
        let now = Date()
        let filtered = buildChain(preferred: preferred, requireVision: requireVision,
                                  requireTools: requireTools, settings: settings, now: now)

        // ── ⑤ 记录当前状态（UI 快照用；**只有这条路径会写 UI 状态**）──
        lastChain = filtered
        let preferredModel = (preferred?.isEmpty == false ? preferred : nil)
            ?? (settings.preferredFreeModel.isEmpty ? nil : settings.preferredFreeModel)
        let currentModel = preferredModel ?? resolvedModel(for: settings.backendKind, settings: settings)
        if let head = filtered.first {
            let isUserPick = head.backend == settings.backendKind && head.model == currentModel
            lastCurrent = head
            if isUserPick {
                lastDegradedReason = nil
                degradedSince = nil
            } else {
                lastDegradedReason = degradationReason(for: head, userBackend: settings.backendKind,
                                                       userModel: currentModel, now: now)
                if degradedSince == nil { degradedSince = now }
            }
        } else {
            lastCurrent = nil
            lastDegradedReason = buildChain(settings: settings, now: now).isEmpty
                ? "候选链为空" : "全部候选被过滤（视觉/工具/冷却）"
        }
        return filtered
    }

    /// 纯聚合（**不写任何状态**）：自检 / tooltip / 预演都用它。
    /// `candidates()` = `buildChain()` + 写 UI 状态。
    private func buildChain(preferred: String? = nil,
                            requireVision: Bool = false,
                            requireTools: Bool = false,
                            settings: AgentSettings? = nil,
                            now: Date? = nil) -> [LLMCandidate] {
        let settings = settings ?? cachedSettings()
        let now = now ?? Date()

        // 有效渠道链
        var chain = settings.effectiveBackends
        if !settings.fallbackEnabled { chain = [settings.backendKind] }
        if chain.isEmpty { chain = [settings.backendKind] }

        // 用户选定模型
        let preferredModel = (preferred?.isEmpty == false ? preferred : nil)
            ?? (settings.preferredFreeModel.isEmpty ? nil : settings.preferredFreeModel)
        let currentModel = preferredModel ?? resolvedModel(for: settings.backendKind, settings: settings)

        var ordered: [LLMCandidate] = []
        var seen = Set<String>()
        func push(_ candidate: LLMCandidate) {
            guard !seen.contains(candidate.key) else { return }
            seen.insert(candidate.key)
            ordered.append(candidate)
        }

        // ── ① 用户选定模型（及其 replacement）──
        let dottedReplacement = records["\(settings.backendKind.rawValue)/\(currentModel)"]?.replacementModel
        if let replacement = dottedReplacement, !replacement.isEmpty {
            push(LLMCandidate(backend: settings.backendKind, model: replacement,
                              supportsVision: false, supportsTools: true,
                              isFree: settings.backendKind.isKeyless))
        }
        if let head = candidate(for: settings.backendKind, model: currentModel, settings: settings, now: now) {
            push(head)
        }

        // ── ② 同渠道其他模型（上次成功时间 ↓ / 上下文长度 ↓）──
        var sameRest = sameBackendRest(settings: settings, currentModel: currentModel, now: now)
        // 用户渠道若连一个 ok 都没有（冷启动全 unknown），其余模型也不急着给：
        // ① 已给了 head 一个，② 再多给只会挤占其它渠道的尝试窗口
        // （消费端只试前 4 个 —— AgentChatService.reply / AgentLoop / LLMSelfTest 一致）。
        if !backendHasOK(settings.backendKind, settings: settings, now: now) {
            sameRest = Array(sameRest.prefix(0))
        }
        for others in sameRest {
            push(others)
        }

        // ── ③ 跨渠道其余渠道（**严格按 LLMBackendKind 声明序**；OVH 走轮转序）──
        //
        // 【为什么这里不许按健康度重排渠道】
        //   W8 在 LLMSelfTest.swift:648 冻结了契约⑦：
        //     「除首个（用户选定）渠道外，其余渠道按 allCases 声明序**严格递增**」。
        //   把"健康渠道提前"（例如 zen 与 legacy 提到 pollinations 之前）会产生
        //   位置序列 `[0,1,3,2]` → rest=[1,3,2] 不递增 → **⑦ 变红**。
        //   而"让健康渠道拿到尝试窗口"这个目标，靠 ② 段的"用户渠道无 ok 就不给
        //   其余模型"已经达成（窗口腾出来了，声明序里 zen/legacy 本就靠前）。
        //   故此处只保持声明序 —— 剔除/缩量可以，跨渠道重排不行。
        for backend in chain where backend != settings.backendKind {
            for candidate in tieredCandidates(for: backend, settings: settings, now: now) {
                push(candidate)
            }
        }

        // ── ④ 能力过滤 + 健康剔除 ──
        //
        // ══════════════════════════════════════════════════════════════════════
        // 【2026-10-06 联调实测修复 · 候选链必须按健康度剔除，否则 A1 直接失败】
        // ══════════════════════════════════════════════════════════════════════
        // 症状（Lead 实测原始输出）：
        //   --llm-probe      → ovhAnonymous 0/5 健康、pollinations 0/6 健康、
        //                      pollinationsLegacy 1/1 ok、zenFree 1/1 ok（健康 2/13）
        //   --llm-selftest --network → 4 个候选全部失败，EXIT=1
        // 根因：原实现只按「用户选定 → 同渠道 → 跨渠道」排，**完全不看健康度**；
        //   而真正 ok 的 pollinationsLegacy / zenFree 被挤出尝试窗口
        //   （消费端只试 4 个：AgentChatService.swift:186、LLMSelfTest.swift:713）。
        //   更隐蔽的是：`cooldownUntil` **不落盘**（重启即清），所以进程重启后
        //   磁盘缓存里那些坏状态候选既不被冷却过滤、也不被健康过滤——
        //   零阻力霸占前 4 名。实测磁盘缓存：ovh 5 个全 rateLimited、
        //   pollinations 6 个全 gated，只有 zen/legacy 为 ok。
        //
        // 【为什么是"剔除"而不是"全局按 ok→unknown 重排"】
        //   重排会打乱渠道分组次序，直接违反 W8 在 LLMSelfTest.swift:578-630
        //   冻结的顺序契约：
        //     ⑦ 渠道分组次序 = LLMBackendKind.allCases 的**严格递增子序列**
        //     ⑧ 同渠道候选**连续成组**（无交错）
        //     ⑨ OVH 候选次序 = 静态轮转表（大到小）的**子序列**
        //   而"剔除"保证链仍是原链的**子序列**——子序列天然继承上述三条性质
        //   （删元素既不会让分组次序倒退，也不会造成交错）。
        //   故此处只剔不排；这与 Lead「或直接剔除，你按现有冷却语义决定」一致。
        //
        // 【剔除边界】只剔"已证明不可用"的：gated / regionBlocked / deprecated /
        //   rateLimited / dead，以及冷却中的。**`.unknown` 一律保留**——
        //   冷启动没探过 ≠ 不可用，它仍是合法候选（排在已知可用者之后不成立，
        //   但绝不能被判死）。
        //
        // 【代价与兜底】若剔除后链为空，说明**确实**没有可用模型（如实返回空，
        //   不编造候选）；消费端会据此如实告知用户"所有渠道均不可达或被限流"。
        //   坏状态有 TTL 自愈：rateLimited 20s、gated 600s 后过期并被重探。
        //
        // 【滤空回退 —— 2026-10-06 实测补强（Lead 要求）】
        //   原则：「试一下」总比「直接宣告无可用」好 —— 真实请求本身就是最强的
        //   探活（这是本文件 task-3 的既定原则，见 noteSuccess/noteFailure）。
        //   若健康过滤把链清空，就回退到「仅排除冷却中」的那批候选：
        //     · 仍排除 `.dead` / `.regionBlocked` —— 这两类是本会话终态，
        //       再试纯属浪费一次往返（且会让用户多等一个必然失败的请求）；
        //     · 保留 `.unknown` / `.rateLimited` / `.gated` / `.deprecated`
        //       —— 它们的 TTL 会过期，重试是有意义的。
        //   回退结果仍是 `ordered` 的**子序列**，故 ⑦⑧⑨ 三条顺序契约不受影响。
        var filtered = ordered.filter { now >= (cooldownUntil[$0.key] ?? .distantPast) }
        filtered = filtered.filter { effectiveHealth($0).isSelectable }
        if requireVision { filtered = filtered.filter(\.supportsVision) }
        if requireTools { filtered = filtered.filter(\.supportsTools) }

        if filtered.isEmpty {
            var fallback = ordered.filter { now >= (cooldownUntil[$0.key] ?? .distantPast) }
            fallback = fallback.filter {
                let health = effectiveHealth($0)
                return health != .dead && health != .regionBlocked
            }
            if requireVision { fallback = fallback.filter(\.supportsVision) }
            if requireTools { fallback = fallback.filter(\.supportsTools) }
            return fallback
        }
        return filtered
    }

    /// 只读快照（**不写任何状态**，供 selfCheck 使用）。
    private func snapshotReadOnly() -> LLMHealthSnapshot {
        let settings = cachedSettings()
        let now = Date()
        var healthy = 0
        var total = 0
        for backend in settings.effectiveBackends {
            for candidate in staticCandidates(for: backend, settings: settings, now: now) {
                total += 1
                if effectiveHealth(candidate) == .ok { healthy += 1 }
            }
        }
        let requireVision = settings.visionEnabled
        let chain = buildChain(requireVision: requireVision, requireTools: false,
                               settings: settings, now: now)
        let current = chain.first
        return LLMHealthSnapshot(
            healthyCount: healthy, totalCount: total, backend: current?.backend,
            backendDisplayName: current?.backend.displayName ?? "无", model: current?.model ?? "",
            latencyMs: lastLatencyMs, degraded: degradedSince != nil,
            degradedReason: lastDegradedReason, lastErrorReason: lastErrorReason,
            isProbing: isProbing,
            chainPreview: chain.prefix(8).map {
                "\(LLMHealthSnapshot.shortName($0.backend))/\($0.model) · \(effectiveHealth($0).displayName)"
            },
            isFreeTier: current.map { $0.isFree || $0.backend.isKeyless } ?? true,
            probeIntervalSeconds: probeInterval,
            visionRequired: requireVision,
            visionModelAvailable: chain.contains { $0.supportsVision })
    }

    /// 降级原因（如实说明，不糊弄）。
    private func degradationReason(for head: LLMCandidate, userBackend: LLMBackendKind,
                                   userModel: String, now: Date) -> String {
        if head.backend != userBackend {
            let key = "\(userBackend.rawValue)/\(userModel)"
            if let until = cooldownUntil[key], until > now {
                return "\(userModel) 冷却中（\(Int(until.timeIntervalSince(now)))s）→ 切 \(head.backend.displayName)"
            }
            if let record = records[key], !record.health.isSelectable {
                return "\(userModel) \(record.health.displayName) → 切 \(head.backend.displayName)"
            }
            return "\(userBackend.displayName) 无可用模型 → 切 \(head.backend.displayName)"
        }
        return "\(userModel) 不可用 → 切 \(head.model)"
    }

    /// 单渠道内按「上次成功时间 ↓ / 上下文长度 ↓」排序其余模型。
    ///
    /// 【OVH 例外】OVH 不参与上下文排序：它的静态表本身就是轮转表
    /// （大到小，core-primitives.js:1779-1788），而 429 的处置是"切表里的
    /// 下一个模型独立桶"。若在这里按 contextLength 重排，Qwen2.5-VL-72B
    /// （32768）会被挤到最后，轮转就失效了 —— 所以 OVH 保持轮转序，
    /// 只在**有过成功记录**的模型之间按成功时间重排。
    ///
    /// 【为什么用「显式分区」而不是 `sorted { ... return false }`】
    ///   Swift 的 `sort` **不保证稳定**：比较器对相等元素返回 false 时，
    ///   相对次序仍可能被重排。实测后果是 OVH 的 ok 层内部轮转相对序被打乱
    ///   （W8 的断言 ⑨(c)「同健康层内保持轮转表相对序」正是抓这个的）。
    ///   故这里用 filter 做**两层稳定分区**：先取 ok 层（保持原序），
    ///   再接非 ok 层（保持原序）—— 分区天然稳定，且语义一眼可读。
    private func sameBackendRest(settings: AgentSettings, currentModel: String, now: Date) -> [LLMCandidate] {
        let list = staticCandidates(for: settings.backendKind, settings: settings, now: now)
            .filter { $0.model != currentModel }
        guard settings.backendKind != .ovhAnonymous else {
            // 轮转序优先；已成功过的模型（.ok）提到前面，避免把上次好用的模型晾着。
            // 两层各自保持 staticCandidates 给出的（轮转）相对序。
            let ok = list.filter { effectiveHealth($0) == .ok }
            let rest = list.filter { effectiveHealth($0) != .ok }
            return ok + rest
        }
        return list.enumerated().sorted { lhs, rhs in
            let l = records[lhs.element.key]?.lastSuccessAt ?? .distantPast
            let r = records[rhs.element.key]?.lastSuccessAt ?? .distantPast
            if l != r { return l > r }
            let lc = lhs.element.contextLength ?? 0
            let rc = rhs.element.contextLength ?? 0
            if lc != rc { return lc > rc }
            return lhs.offset < rhs.offset   // 稳定兜底：保持静态表序
        }.map(\.element)
    }

    /// 渠道模型清单（静态表 + 已知运行时扩展 + replacement），**按可选择性排序**。
    ///
    /// OVH 走轮转序：静态表本身是"大到小"（core-primitives.js:1779-1788），
    /// 轮转游标保证 429 后下一个请求落在**另一个独立匿名桶**，而不是重撞同一个。
    private func staticCandidates(for backend: LLMBackendKind, settings: AgentSettings,
                                  now: Date = Date()) -> [LLMCandidate] {
        var list: [LLMCandidate] = []
        // userKey 的模型清单是运行时拉取的（W1 静态表为空），必须传 baseUrl 才拿到
        let override: String? = backend == .userKey ? settings.baseUrl : nil
        if let descriptor = LLMHealthMonitor.descriptor(for: backend, baseURLOverride: override),
           !descriptor.staticModels.isEmpty {
            list = descriptor.staticModels.map { LLMCandidate($0, backend: backend) }
        } else {
            let model = resolvedModel(for: backend, settings: settings)
            if !model.isEmpty {
                list = [LLMCandidate(backend: backend, model: model, supportsVision: false,
                                     supportsTools: true, isFree: backend.isKeyless)]
            }
        }

        // 运行时发现的模型（refreshModelCatalog 写入的元数据）补进来
        for info in runtimeCatalog[backend] ?? [] where !list.contains(where: { $0.model == info.id }) {
            list.append(LLMCandidate(info, backend: backend))
        }
        // 真实失败暴露出的 replacement 补进来（它是上游亲口说的可用替代）
        for (key, record) in records {
            guard key.hasPrefix("\(backend.rawValue)/"),
                  let replacement = record.replacementModel, !replacement.isEmpty,
                  !list.contains(where: { $0.model == replacement }) else { continue }
            list.append(LLMCandidate(backend: backend, model: replacement, supportsVision: false,
                                     supportsTools: true, isFree: backend.isKeyless))
        }

        if backend == .ovhAnonymous { list = rotateOVH(list) }
        return list
    }

    /// 构造单个候选（找不到描述符时用 settings.model 兜底）。
    private func candidate(for backend: LLMBackendKind, model: String,
                           settings: AgentSettings, now: Date) -> LLMCandidate? {
        guard !model.isEmpty else { return nil }
        if let known = staticCandidates(for: backend, settings: settings, now: now)
            .first(where: { $0.model == model }) {
            return known
        }
        return LLMCandidate(backend: backend, model: model, supportsVision: false,
                            supportsTools: true, isFree: backend.isKeyless)
    }

    /// 该渠道是否至少有一个模型被**已探明健康**（.ok）。
    ///
    /// 用途：buildChain 的 ② 段据此决定"同渠道其余模型"给不给。
    ///   冷启动时（全 .unknown）返回 false → ② 段给空 → **把尝试窗口让给
    ///   其它渠道**。这正对应 Lead 的"同渠道连续失败 → 跳渠道"：
    ///   上游配额的共享特性（OVH 实测 4 个模型连续 429）意味着"同渠道其余
    ///   模型"在用户渠道全坏时多半也是坏的，给它们排满前 4 只会浪费机会。
    private func backendHasOK(_ backend: LLMBackendKind, settings: AgentSettings, now: Date) -> Bool {
        staticCandidates(for: backend, settings: settings, now: now)
            .contains { effectiveHealth($0) == .ok }
    }

    /// 渠道内按健康态分层的模型清单（**只排组内顺序，不跨渠道重排**）。
    ///
    /// 组内顺序 = [已探明健康 .ok] → [未知 .unknown] → [失败态且未冷却]
    ///   （失败态：rateLimited/gated/regionBlocked/deprecated/dead，按 chainTier 稳定排）。
    /// 该排序**只发生在单个渠道的组内**，所以不会违反 W8 冻结的：
    ///   ⑦ 跨渠道分组次序（仍按声明序） / ⑧ 同渠道连续成组 / ⑨ OVH 轮转子序列。
    ///
    /// 【OVH 例外】OVH 不参与组内分层：它的静态表就是轮转表（大到小），
    ///   且 429 的处置是"切表里下一个模型的独立桶"。若按健康态重排，
    ///   Qwen2.5-VL-72B 会被挤到后面，轮转就失效了 —— 所以 OVH 整组保持
    ///   轮转序（由 rotateOVH 保证），只靠**顶层剔除**把整组坏模型拿掉。
    private func tieredCandidates(for backend: LLMBackendKind, settings: AgentSettings,
                                  now: Date) -> [LLMCandidate] {
        let list = staticCandidates(for: backend, settings: settings, now: now)
        if backend == .ovhAnonymous { return list }   // 轮转序优先，组内不重排

        var ok: [LLMCandidate] = []
        var unknown: [LLMCandidate] = []
        var failed: [LLMCandidate] = []
        for candidate in list {
            let health = effectiveHealth(candidate)
            switch health {
            case .ok:            ok.append(candidate)
            case .unknown:       unknown.append(candidate)
            case .gated, .regionBlocked, .deprecated, .rateLimited, .dead:
                failed.append(candidate)
            }
        }
        // 组内稳定排：同健康层保持静态表序（用原始 offset 作稳定键）
        func offset(_ c: LLMCandidate) -> Int { list.firstIndex(of: c) ?? 0 }
        failed.sort { offset($0) < offset($1) }
        return ok + unknown + failed
    }

    /// 当前应使用的模型（用户显式首选 > OVH 轮转位 > settings.model > 静态表首个）。
    private func resolvedModel(for backend: LLMBackendKind, settings: AgentSettings) -> String {
        if !settings.preferredFreeModel.isEmpty { return settings.preferredFreeModel }
        if backend == .ovhAnonymous, let first = rotateOVH(staticModelsOnly(for: backend)).first {
            return first.model
        }
        if !settings.model.isEmpty { return settings.model }
        return staticModelsOnly(for: backend).first?.model ?? ""
    }

    private func staticModelsOnly(for backend: LLMBackendKind) -> [LLMCandidate] {
        guard let descriptor = LLMHealthMonitor.descriptor(for: backend) else { return [] }
        return descriptor.staticModels.map { LLMCandidate($0, backend: backend) }
    }

    // MARK: OVH 轮转

    /// 按静态表顺序轮转（大到小），从当前游标开始。
    private func rotateOVH(_ models: [LLMCandidate]) -> [LLMCandidate] {
        guard !models.isEmpty else { return [] }
        let count = models.count
        let start = ((ovhRotationCursor % count) + count) % count
        return Array(models[start...] + models[..<start])
    }

    /// 请求成功后粘住当前模型：成功就不该乱换（省配额、保上下文一致）。
    private func stickyOVHCursor(to candidate: LLMCandidate) {
        guard let models = LLMHealthMonitor.descriptor(for: .ovhAnonymous)?.staticModels,
              let index = models.firstIndex(where: { $0.id == candidate.model }) else { return }
        ovhRotationCursor = index
    }

    /// 429 / 门禁 → 立刻切下一个模型的独立匿名桶（出处 core-primitives.js:1780-1782）。
    private func advanceOVHRotation(reason: String) {
        let count = LLMHealthMonitor.descriptor(for: .ovhAnonymous)?.staticModels.count ?? 0
        guard count > 0 else { return }
        ovhRotationCursor = (ovhRotationCursor + 1) % count
        NSLog("[LLMHealth] OVH 轮转 → 下一个模型（\(reason)）")
    }

    /// 供 W7/W6 手动推进轮转（例如连续 429 后主动换桶）。
    func rotateOVHToNextModel() { advanceOVHRotation(reason: "manual") }

    // MARK: - 4. UI 快照

    /// UI 底部小字的数据源（健康数/总数、当前模型、延迟、是否降级中）。
    func snapshot() async -> LLMHealthSnapshot {
        let settings = cachedSettings()
        let now = Date()
        var healthy = 0
        var total = 0
        for backend in settings.effectiveBackends {
            for candidate in staticCandidates(for: backend, settings: settings, now: now) {
                total += 1
                if effectiveHealth(candidate) == .ok { healthy += 1 }
            }
        }
        // ══════════════════════════════════════════════════════════════════════
        // 【2026-10-06 实测修复 · 小字不许在"有健康模型"时说"无可用模型"】
        // ══════════════════════════════════════════════════════════════════════
        // 症状（`--llm-probe` 实测）：
        //     · ovhAnonymous: 1/5 健康 / pollinationsLegacy: 1/1 / zenFree: 1/1
        //     ✅ 至少一个模型探活为 ok  健康 3/13
        //     小字: ⚠️ 无可用模型（点此诊断）   ← 自相矛盾
        // 根因：原实现取 `lastCurrent`，而它**只有 `candidates()` 被调用过才非 nil**。
        //   `--llm-probe` 只跑 `probeAll` + `snapshot()`，从不调 `candidates()`
        //   → `lastCurrent == nil` → `model == ""` → displayLine 误报"无可用模型"。
        //   底部小字是用户**唯一**的状态窗口，说错话比不说更糟（用户会以为
        //   整个 AI 挂了，其实只是没被"取链"过）。故此处**现场推导**当前候选：
        //     · lastCurrent 有值（UI 正在用）→ 优先沿用它，保持与聊天路径一致；
        //     · 否则用 buildChain 现算（只读，不写 UI 状态）。
        // ══════════════════════════════════════════════════════════════════════
        // 【2026-10-06 用户指正修复 · 小字必须反映"视觉开关"的实际情况】
        // ══════════════════════════════════════════════════════════════════════
        // 用户指出：小字显示 `免费档 · ovh · Qwen3.5-9B`，而 **Qwen3.5-9B 是纯文本模型**
        //   （LLMBackend.swift:295 `supportsVision: false`）；OVH 那 5 个里只有
        //   `Qwen2.5-VL-72B-Instruct` 带视觉。
        // 问题不在"选错模型"——纯文本模式下选纯文本模型**是对的**；问题在于
        //   **小字没有区分"开没开视觉"**：用户一旦打开 📷，聊天链路会走
        //   `requireVision: true` 的候选链（只有 VL-72B），可小字还显示 Qwen3.5-9B，
        //   看起来就像"拿纯文本模型看图"。
        // 修法：小字按**当前实际会用的链路**推导——
        //   · visionEnabled=true → 用视觉候选链推导（并显示 👁 标记）
        //   · visionEnabled=false → 用普通链（原行为）
        //   · 开了视觉但**没有任何视觉候选** → 如实显示"无可用视觉模型"，不假装。
        let requireVision = settings.visionEnabled
        let derived = requireVision
            ? buildChain(requireVision: true, requireTools: false, settings: settings, now: now).first
            : (lastCurrent ?? buildChain(settings: settings, now: now).first)
        let chainForPreview = requireVision
            ? buildChain(requireVision: true, requireTools: false, settings: settings, now: now)
            : (lastChain.isEmpty ? buildChain(settings: settings, now: now) : lastChain)
        return LLMHealthSnapshot(
            healthyCount: healthy,
            totalCount: total,
            backend: derived?.backend,
            backendDisplayName: derived?.backend.displayName ?? "无",
            model: derived?.model ?? "",
            latencyMs: lastLatencyMs,
            degraded: degradedSince != nil,
            degradedReason: lastDegradedReason,
            lastErrorReason: lastErrorReason,
            isProbing: isProbing,
            chainPreview: chainForPreview.prefix(8).map {
                "\(LLMHealthSnapshot.shortName($0.backend))/\($0.model) · \(effectiveHealth($0).displayName)"
            },
            isFreeTier: derived.map { $0.isFree || $0.backend.isKeyless } ?? true,
            probeIntervalSeconds: probeInterval,
            visionRequired: requireVision,
            visionModelAvailable: chainForPreview.contains { $0.supportsVision }
        )
    }

    /// 生效健康态 = 冷却覆盖 + TTL 过期 + 记录状态。
    ///
    /// 【TTL 过期必须在这里生效，而不只是在"是否重探"里】
    ///   原先 TTL 只用于 `isFresh()`（决定要不要重探），**读取时永不失效**。
    ///   后果：某个模型被判断过一次 `rateLimited` 后，即使再过一小时，
    ///   `effectiveHealth` 仍返回 rateLimited → 候选链把它永久剔除，
    ///   而 `cooldownUntil` 又不落盘（重启即清）——两边叠加就成了
    ///   "磁盘缓存里一条陈旧坏记录，能把一个其实已恢复的渠道永久挡在门外"。
    ///   实测就踩到了：缓存里 ovh 5 个全是 rateLimited，链首因此永远轮不到它们。
    ///   所以这里让过期坏状态**回归 `.unknown`**：它重新成为合法候选，
    ///   并且下一次 `isFresh()` 判定会真的去重探它 —— 这才是自愈。
    ///
    /// 【哪些会过期】
    ///   ok 60s / rateLimited 20s / gated 600s → 过期回归 unknown（可再试）
    ///   deprecated / dead / regionBlocked → `ttl = .greatestFiniteMagnitude`
    ///   （本会话终态，不过期）—— 这三类重探是纯浪费配额，见 ttl(for:) 注释。
    ///
    /// 注意：`.unknown` 在候选筛选里是"可选"（冷启动未探），但**不计入健康数**，
    /// 免得 UI 显示"健康 44/44"骗人。
    func effectiveHealth(_ candidate: LLMCandidate) -> ModelHealth {
        // ① 冷却未到 → 不可选（原逻辑保留）
        if let until = cooldownUntil[candidate.key], until > Date() {
            return records[candidate.key]?.health == .ok ? .rateLimited : (records[candidate.key]?.health ?? .rateLimited)
        }
        guard let record = records[candidate.key], record.health != .unknown else { return .unknown }
        // ② TTL 过期 → 已知结论作废，回到「未探测」（可候选，且会被重探）
        let ttl = LLMHealthMonitor.ttl(for: record.health)
        if ttl.isFinite, Date().timeIntervalSince(record.checkedAt) >= ttl {
            return .unknown
        }
        return record.health
    }

    /// 某候选的原始记录（tooltip / 调试用）。
    func record(for candidate: LLMCandidate) -> HealthRecord? { records[candidate.key] }

    /// 全部已知候选键 → 健康态（W8 自检与诊断面板用）。
    func allHealthStates() -> [String: ModelHealth] {
        let settings = cachedSettings()
        var out: [String: ModelHealth] = [:]
        for backend in settings.effectiveBackends {
            for candidate in staticCandidates(for: backend, settings: settings) {
                out[candidate.key] = effectiveHealth(candidate)
            }
        }
        return out
    }

    // MARK: - 5. 双层缓存（内存 + 磁盘）

    /// 磁盘缓存文件（与 API Key 小本本同目录，0600）。
    static var cacheFileURL: URL {
        // 【AURORA_LLM_HEALTH_CACHE 覆盖】仅用于**离线自检**：让自检把缓存写到
        // 临时目录，而不是用户的 Application Support。生产路径不设该变量，
        // 行为与不加这几行完全一致。自检若直接写用户目录，等于污染真实配置。
        if let override = ProcessInfo.processInfo.environment["AURORA_LLM_HEALTH_CACHE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return AgentSettings.notebookURL
            .deletingLastPathComponent()
            .appendingPathComponent("llm-health-cache.json")
    }

    /// 落盘结构。**只存"一小时内不会变"的事实**；冷却态（熔断/429）不落盘。
    private struct DiskEntry: Codable {
        var health: ModelHealth
        var checkedAt: Date
        var lastSuccessAt: Date?
        var latencyMs: Double?
        var replacementModel: String?
    }

    private struct DiskPayload: Codable {
        var version: Int
        var entries: [String: DiskEntry]
    }

    private static func loadDiskRecords() -> [String: HealthRecord] {
        let url = cacheFileURL
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(DiskPayload.self, from: data),
              payload.version == 1 else { return [:] }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
        if let mtime, Date().timeIntervalSince(mtime) > diskCacheMaxAge { return [:] }
        var out: [String: HealthRecord] = [:]
        for (key, entry) in payload.entries {
            // regionBlocked / dead 是「本会话」概念，重启后重探一次更诚实。
            guard entry.health != .regionBlocked, entry.health != .dead else { continue }
            out[key] = HealthRecord(health: entry.health,
                                    checkedAt: entry.checkedAt,
                                    lastSuccessAt: entry.lastSuccessAt,
                                    latencyMs: entry.latencyMs,
                                    replacementModel: entry.replacementModel,
                                    reason: "磁盘缓存")
        }
        return out
    }

    /// 落盘（**非隔离静态方法**：编码 + 写文件都在 actor 外，
    /// 不占用 actor 执行器，更不碰主线程）。
    ///
    /// 只存「一小时内不会变」的事实：ok / gated / deprecated（含替代模型）。
    ///
    /// 【哪些坚决不落盘】
    ///   · `rateLimited` —— 这是**冷却态**（task-3 规格：「冷却状态不落盘，重启即清」）。
    ///     实测教训：本函数早先漏了这一个 case，于是 429 被写进磁盘；而
    ///     `cooldownUntil` 本身是不落盘的，重启后「状态是 rateLimited、冷却却已失效」
    ///     两边对不上，坏候选既不被冷却拦、又被健康分层剔除，行为变得难以解释。
    ///     重启后应当**重探**，而不是继承一条可能早已过期的限流结论。
    ///   · `regionBlocked` / `dead` —— 会话级/环境级判断，重探一次更诚实。
    ///   · `unknown` —— 没有信息量。
    private nonisolated static func persist(records: [String: HealthRecord]) async {
        var entries: [String: DiskEntry] = [:]
        for (key, record) in records {
            guard record.health != .unknown, record.health != .regionBlocked,
                  record.health != .dead, record.health != .rateLimited else { continue }
            entries[key] = DiskEntry(health: record.health,
                                     checkedAt: record.checkedAt,
                                     lastSuccessAt: record.lastSuccessAt,
                                     latencyMs: record.latencyMs,
                                     replacementModel: record.replacementModel)
        }
        guard let data = try? JSONEncoder().encode(DiskPayload(version: 1, entries: entries)) else { return }
        let url = cacheFileURL
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }.value
    }

    /// 清空内存 + 磁盘缓存（诊断面板"重新探测"用）。
    func resetCache() {
        records.removeAll()
        consecutiveFailures.removeAll()
        cooldownUntil.removeAll()
        ovhRotationCursor = 0
        lastCurrent = nil
        lastChain = []
        degradedSince = nil
        lastErrorReason = nil
        lastFullProbeAt = .distantPast
        try? FileManager.default.removeItem(at: LLMHealthMonitor.cacheFileURL)
    }

    // MARK: - 6. 配置 / 模型目录

    private func cachedSettings() -> AgentSettings {
        let now = Date()
        if let cached = settingsCache, now.timeIntervalSince(settingsCachedAt) < LLMHealthMonitor.settingsCacheTTL {
            return cached
        }
        let loaded = AgentSettings.load()
        settingsCache = loaded
        settingsCachedAt = now
        return loaded
    }

    /// 设置变更后调用（W6 保存配置时），让下一次聚合立刻读到新值。
    func invalidateSettingsCache() {
        settingsCache = nil
        settingsCachedAt = .distantPast
    }

    /// 运行时模型目录（`GET /models` 的结果缓存，不落盘）。
    private var runtimeCatalog: [LLMBackendKind: [LLMModelInfo]] = [:]

    /// 拉取某渠道的运行时模型目录（**显式调用**，聊天路径不会自动联网）。
    /// 失败时静默保留静态表——静态表是 W1 的实测数据，比"没结果"强。
    func refreshModelCatalog(backend: LLMBackendKind) async {
        let settings = cachedSettings()
        // .userKey 必须带 baseURLOverride，否则拿到的是出厂默认端点（不是用户填的）
        guard let provider = LLMBackendRegistry.shared.provider(for: backend,
                                                               apiKey: settings.apiKey,
                                                               baseURLOverride: settings.baseUrl) else { return }
        if let models = try? await provider.models(apiKey: settings.apiKey), !models.isEmpty {
            runtimeCatalog[backend] = models
        }
    }

    // MARK: - 7. 纯逻辑自检（W8 用；不触碰状态）

    /// 纯函数：上游信号分类。不依赖网络，可离线断言。
    ///
    /// 判定顺序：错误类型关键字 → 区域/门禁关键字 → 限流关键字 → HTTP 状态码。
    ///
    /// ══════════════════════════════════════════════════════════════════════════
    /// 【403 到底算什么 —— 2026-10-06 实测澄清（Lead 提问）】
    /// ══════════════════════════════════════════════════════════════════════════
    /// 观察到的现象：**同一 OVH 端点出现过两种响应**——
    ///   · `429 API rate limit exceeded`（不带 Authorization）
    ///   · `403 Forbidden: authentication failed`（带了一把无效的 Bearer）
    /// W8 的 curl 三分对照（verify/evidence-llm/ovh-key-vs-nokey-curl.txt）证实：
    ///   同一个 body、同一个端点，**只改 Authorization 头**就得到不同状态码：
    ///     不发 Authorization → 429（真实状态：限流）
    ///     空 Authorization  → **200 成功**（匿名层可用）
    ///     Bearer <旧 key>   → **403**（"你给了一把无效的 key"）
    /// 结论：**403 不是 OVH 在收紧匿名层，而是调用方错误地附带了无效凭据。**
    ///   所以对**免 key 渠道**，403 不能记成 `.keyInvalid`（那会写进健康态并把
    ///   归因写成"Key 无效"，掩盖真实的"渠道本来免 key、是我们多发了个头"）。
    ///   它也不是"配额耗尽"（那是 429）。
    ///   此处归为 `.keyInvalid`，由上层的 `probeOnce` 再按 `requiresKey` 二次判定：
    ///   免 key 渠道的 keyInvalid → 改判 `.freeTier`（门的语义 = 这次调用没被接受，
    ///   冷却后重试；而不是把模型判死）。
    ///
    /// 【对 OVH 的如实记录】匿名层**会限流**（429 实测复现多次），
    ///   且当前实测 5 个模型全部 429。**不得写成"永久可用"**——
    ///   本文件任何地方都不做该承诺；W1 的 riskNote 也已如实标注可能限流。
    ///   当前策略是靠 `rateLimited` + 20s TTL 自愈，并用 OVH 的
    ///   per-model 独立桶轮转（429 就换下一个模型）来摊薄配额压力。
    static func classifyProbeSignal(httpStatus: Int, errorType: String?, bodyText: String) -> LLMProbeSignal {
        let type = (errorType ?? "").lowercased()
        let body = bodyText.lowercased()

        func matches(_ needle: String) -> Bool { type.contains(needle) || body.contains(needle) }

        if matches("freetiererror") || matches("free tier") || matches("tiererror") { return .freeTier }
        if matches("regionerror") || matches("region_blocked") { return .region }
        if matches("modeldeprecated") || matches("deprecated") { return .deprecated(replacement: nil) }
        if matches("modelnotfound") || matches("model not found") || matches("does not exist")
            || matches("unknown model") || matches("no such model") { return .notFound }
        // 限流关键字必须排在状态码之前：OVH 限流返回的是**裸 message 体**
        // （`{"message":"API rate limit exceeded",...}`，无 error.type），
        // 只靠 httpStatus == 429 也能兜住，但显式匹配让 body 可读性更好。
        if matches("ratelimit") || matches("rate limit") || matches("too many requests")
            || httpStatus == 429 { return .rateLimited(retryAfter: nil) }
        // 鉴权失败关键字（含 OVH 实测的 "authentication failed"）
        if matches("authentication failed") || matches("invalid api key") || matches("unauthorized") {
            return .keyInvalid
        }

        switch httpStatus {
        case 200...299: return .healthy
        case 401, 407:  return .keyInvalid
        // 403 归 .keyInvalid，但**免 key 渠道会被 probeOnce 改判为 .freeTier**
        // （见本函数注释的实测三分对照：403 的成因是"附带无效凭据"，
        //   对免 key 渠道而言是我们的调用方式问题，不是渠道永久关门）
        case 403:       return .keyInvalid
        case 404:       return .notFound
        case 500...599: return .serverError(httpStatus)
        default:        return .serverError(httpStatus)
        }
    }

    /// 纯函数：熔断判定（连续失败达到阈值即开路）。
    static func shouldOpenCircuit(consecutiveFailures: Int) -> Bool {
        consecutiveFailures >= circuitBreakerThreshold
    }

    /// 探活间隔是否合法（环境变量防护）。<5s 一律拒绝。
    static func isAcceptableProbeInterval(_ seconds: Double) -> Bool {
        seconds >= minimumProbeInterval
    }

    /// OVH 静态表的期望顺序（大到小）。
    /// 出处：dsh-vision-router/src/lib/core-primitives.js:1779-1788。
    /// **这是断言用的期望值**，不是数据源——真正的模型数据以 W1 的描述符为准。
    static let expectedOVHOrder = [
        "Qwen3.5-397B-A17B",
        "Qwen2.5-VL-72B-Instruct",
        "Qwen3.6-27B",
        "Mistral-Small-3.2-24B-Instruct-2506",
        "Qwen3.5-9B",
    ]

    /// 离线自检：不联网、不改状态，只验证纯逻辑与不变量。
    func selfCheck() async -> LLMHealthSelfCheck {
        var checks: [String] = []
        var failures: [String] = []

        // ① OVH 轮转顺序（大到小）
        if let models = LLMHealthMonitor.descriptor(for: .ovhAnonymous)?.staticModels.map(\.id) {
            let expected = LLMHealthMonitor.expectedOVHOrder
            var cursor = 0
            var inOrder = true
            for name in expected {
                guard let found = models[cursor...].firstIndex(of: name) else { inOrder = false; break }
                cursor = found + 1
            }
            if inOrder && !expected.isEmpty {
                checks.append("OVH 静态表按大到小轮转（\(expected.count) 模型）")
            } else {
                failures.append("OVH 静态表顺序不符合大到小：\(models)")
            }
            if models.count != expected.count {
                checks.append("OVH 静态表模型数 = \(models.count)（期望值 \(expected.count)，仅提示）")
            }
        } else {
            failures.append("取不到 ovhAnonymous 描述符（W1 LLMBackend 未落地或签名不符）")
        }

        // ② 探活间隔下限
        if LLMHealthMonitor.isAcceptableProbeInterval(probeInterval) {
            checks.append("探活间隔 \(Int(probeInterval))s ≥ 5s（免费档保护）")
        } else {
            failures.append("探活间隔 \(probeInterval)s 过小，会打死免费档")
        }
        if probeInterval >= 30 {
            checks.append("默认/覆盖间隔 ≥ 30s")
        }

        // ③ 分类纯函数（W8 负向对照的靶点之一）
        let gated = LLMHealthMonitor.classifyProbeSignal(
            httpStatus: 200, errorType: "FreeTierError",
            bodyText: "{\"type\":\"error\",\"error\":{\"type\":\"FreeTierError\"}}")
        if gated == .freeTier { checks.append("FreeTierError → gated") }
        else { failures.append("FreeTierError 分类错误：\(gated)") }

        let region = LLMHealthMonitor.classifyProbeSignal(
            httpStatus: 403, errorType: "RegionError", bodyText: "")
        if region == .region { checks.append("RegionError → regionBlocked") }
        else { failures.append("RegionError 分类错误：\(region)") }

        let limited = LLMHealthMonitor.classifyProbeSignal(httpStatus: 429, errorType: nil, bodyText: "")
        if case .rateLimited = limited { checks.append("429 → rateLimited") }
        else { failures.append("429 分类错误：\(limited)") }

        let gone = LLMHealthMonitor.classifyProbeSignal(
            httpStatus: 400, errorType: "ModelDeprecated", bodyText: "")
        if case .deprecated = gone { checks.append("ModelDeprecated → deprecated") }
        else { failures.append("ModelDeprecated 分类错误：\(gone)") }

        // ④ 熔断阈值
        if !LLMHealthMonitor.shouldOpenCircuit(consecutiveFailures: 2),
           LLMHealthMonitor.shouldOpenCircuit(consecutiveFailures: 3) {
            checks.append("熔断：2 次不熔断、3 次熔断")
        } else {
            failures.append("熔断阈值不是 3 次")
        }

        // ⑤ 候选聚合不变量（vision 过滤 / 去重 / 冷却剔除）
        //
        // 【为什么用 buildChain 而不是 candidates()】candidates() 会写
        // lastCurrent / lastChain / degradedSince（UI 快照状态），自检跑一遍
        // 就会把 UI 的"当前模型"改掉。selfCheck 必须**只读**，
        // 所以这里走纯函数版聚合（不写任何状态）。
        let visionChain = buildChain(requireVision: true, requireTools: false)
        if visionChain.allSatisfy(\.supportsVision) {
            checks.append("requireVision=true 时全部候选支持视觉（\(visionChain.count) 个）")
        } else {
            failures.append("requireVision 过滤失效：\(visionChain.map(\.key))")
        }
        if Set(visionChain.map(\.key)).count == visionChain.count {
            checks.append("候选链无重复")
        } else {
            failures.append("候选链存在重复 key")
        }
        let now = Date()
        if visionChain.allSatisfy({ now >= (cooldownUntil[$0.key] ?? .distantPast) }) {
            checks.append("冷却中的候选已被剔除")
        } else {
            failures.append("冷却中的候选仍在链上")
        }

        // ⑥ 未探活时不得谎报健康
        let snapshotValue = snapshotReadOnly()
        if snapshotValue.healthyCount <= snapshotValue.totalCount {
            checks.append("健康数 \(snapshotValue.healthyCount)/\(snapshotValue.totalCount) 自洽")
        } else {
            failures.append("健康数超过总数：\(snapshotValue.healthyCount)/\(snapshotValue.totalCount)")
        }

        return LLMHealthSelfCheck(ok: failures.isEmpty, checks: checks, failures: failures)
    }

    // MARK: - 8. 渠道描述符桥接（唯一对外依赖：W1 LLMBackend.swift）

    /// 取渠道描述符。**全文件只有这一处依赖 W1 的 API 形状**，
    /// W1 签名若有出入，只改这个函数。
    ///
    /// 【已核对落盘真身】LLMBackend.swift:796-799 —— `final class LLMBackendRegistry:
    /// @unchecked Sendable` + `static let shared`，`descriptor(for:)` 是**实例方法**。
    /// （Lead 2026-10-06 转述的"enum + 静态方法、没有 .shared"与本文件实际不符：
    ///  全树仅此一处声明，且 W7 AgentLoop.swift:513 同样调用 `.shared.descriptor(...)`。）
    ///
    /// 【必须传 baseURLOverride】`.userKey` 渠道的端点是用户填的 `settings.baseUrl`；
    /// 不传 override 会拿到 W1 出厂默认端点（AgentSettings().baseUrl），
    /// 于是"探活打到别人的服务器上、却报告我的端点健康"——实测踩过这个坑。
    private nonisolated static func descriptor(for kind: LLMBackendKind,
                                              baseURLOverride: String? = nil) -> LLMBackendDescriptor? {
        LLMBackendRegistry.shared.descriptor(for: kind, baseURLOverride: baseURLOverride)
    }

    // MARK: - 9. 探活 HTTP（最小实现，只判可达性）

    private struct ProbeOutcome: Sendable {
        var signal: LLMProbeSignal
        var latencyMs: Double
    }

    /// 独立 URLSession：**不与 captureQueue / aurora.quest.ocr 共用**，
    /// 也不与 W2 的传输层共用，避免互相排队（性能红线）。
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = probeTimeoutSeconds
        config.timeoutIntervalForResource = probeTimeoutSeconds + 2
        // 【为什么是 2×并发数，而不是等于并发数】
        //   任务并发是 3。若连接上限也设 3，那么当某台主机**挂住不回**
        //   （既不断开也不报错，实测 OVH 限流时会这样）时，挂住的那条连接
        //   会占满整池，后续请求在队列里干等到自己的 8s 超时 —— 一轮探活
        //   被一个坏连接拖成两倍以上。留一倍余量（6）让排队永不成为瓶颈，
        //   真正的上界仍由每个请求的 8s 硬超时保证。
        config.httpMaximumConnectionsPerHost = probeConcurrency * 2
        return URLSession(configuration: config)
    }()

    /// 一次探活：POST {base}/chat/completions，极短 prompt。
    ///
    /// 【为什么不复用 W2 的 LLMTransport】
    ///   健康探活要的是"端点与模型可达"，需要 8s 硬超时 + 独立 session，
    ///   且**不能**污染真实请求的连接/取消语义。两者目标不同，故独立实现，
    ///   但错误分类语义与 W2 保持一致（classifyProbeSignal）。
    private nonisolated static func probeOnce(_ candidate: LLMCandidate,
                                              apiKey: String?,
                                              timeout: TimeInterval,
                                              baseURLOverride: String? = nil) async -> ProbeOutcome {
        let started = Date()
        func elapsed() -> Double { Date().timeIntervalSince(started) * 1000 }

        // .userKey：直接用调用方传来的 settings.baseUrl（不传就会打到 W1 出厂默认端点）
        guard let descriptor = descriptor(for: candidate.backend,
                                          baseURLOverride: baseURLOverride) else {
            return ProbeOutcome(signal: .transport("渠道描述符缺失"), latencyMs: elapsed())
        }
        // 优先用 W1 的完整端点串（含 query 与实测路径），没有再退化到 baseURL + "/chat/completions"
        let endpoint = descriptor.chatCompletionsURLString.isEmpty
            ? descriptor.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
            : descriptor.chatCompletionsURLString
        guard let url = URL(string: endpoint) else {
            return ProbeOutcome(signal: .transport("URL 非法：\(endpoint)"), latencyMs: elapsed())
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 描述符自带的头优先（Zen 的 UA / x-opencode-session / Bearer public 都在里面）
        for (field, value) in descriptor.extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let key = apiKey, !key.isEmpty, candidate.backend.requiresKey,
           request.value(forHTTPHeaderField: "Authorization") == nil {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        // 免 key 且描述符没给 Authorization 时**刻意不加**该头（OVH 要空 Authorization）

        // max_tokens 取小值：探活只验证可达，不消耗配额做生成
        let body: [String: Any] = [
            "model": candidate.model,
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 4,
            "temperature": 0,
            "stream": false,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await probeSession.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bodyText = String(data: data.prefix(4096), encoding: .utf8) ?? ""

            var errorType: String?
            var replacement: String?
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let errorObject = object["error"] as? [String: Any] {
                    errorType = errorObject["type"] as? String
                    if let metadata = errorObject["metadata"] as? [String: Any] {
                        replacement = metadata["replacement"] as? String
                    }
                } else if let type = object["type"] as? String, type.lowercased() == "error" {
                    errorType = (object["error"] as? [String: Any])?["type"] as? String
                }
            }

            var signal = classifyProbeSignal(httpStatus: http, errorType: errorType, bodyText: bodyText)
            // 免 key 渠道收到 401/403：不是"探活配错 key"，而是该渠道对匿名调用
            // 关门了（W1 实测 gen.pollinations.ai chat 端点 401）。按门禁处置。
            if signal == .keyInvalid, !candidate.backend.requiresKey { signal = .freeTier }
            if case .deprecated = signal, let replacement {
                signal = .deprecated(replacement: replacement)
            }
            if case .rateLimited = signal {
                let retryAfter = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
                signal = .rateLimited(retryAfter: retryAfter)
            }
            return ProbeOutcome(signal: signal, latencyMs: elapsed())
        } catch {
            let code = (error as? URLError)?.code
            let reason = code == .timedOut ? "超时 \(Int(timeout))s" : "\(error.localizedDescription)"
            return ProbeOutcome(signal: .transport(reason), latencyMs: elapsed())
        }
    }
}
