// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  AgentSettings.swift — AI 助手配置（W0 接口冻结 · 2026-10-06）
// ============================================================================
//
//  【为什么单独抽出来】
//    原定义在 AIAgentPanel.swift:81，与 2680 行的面板 UI 混在一起。
//    本次「多渠道聚合 + 降级链 + 工具挂载」施工由 8 条线并行推进，
//    配置结构是**所有线的公共依赖**；抽出成独立文件后：
//      · 写作用域清晰（本文件只有 W0/Lead 改，其他线只读）
//      · 避免 8 条线同时编辑 AIAgentPanel.swift 造成冲突
//
//  【红线：不内置任何 API Key】
//    本文件**不得**出现任何硬编码密钥。用户 key 存本地 0600 小本本，
//    免 key 渠道（OVH/Zen/Pollinations）走 public / 空 Authorization。
//
// ============================================================================

import Foundation

// MARK: - 后端渠道种类（7 提供方 + 自定义）

/// AI 助手可用的模型提供方。
///
/// 分两层：**免 key 层**（用户零配置即用）与**需 key 层**（注册后免费）。
/// 排序即默认降级链顺序（见 LLMHealthMonitor.candidates）。
enum LLMBackendKind: String, Codable, CaseIterable, Sendable {
    // ── 免 key 层（无需注册、无需 API Key）──
    /// OVHcloud AI Endpoints 匿名层。
    /// 出处：dsh-vision-router/src/lib/core-primitives.js:1779-1788
    /// （`apiKeyEnv: ''` = 不要 key；配额 per IP AND per model，429 可切下一个模型独立桶）
    case ovhAnonymous
    /// OpenCode Zen 免费档。需三头注入（UA + x-opencode-session + Bearer public）。
    /// 实测：14 个免费模型中仅 space-bunny-free 存活，但**视觉可用**（真实截图读出中文）
    case zenFree
    /// Pollinations 新 API（gen.pollinations.ai）。实测 37 个文本模型免 key。
    case pollinations
    /// Pollinations 旧 API（text.pollinations.ai）——单模型兜底。
    case pollinationsLegacy

    // ── 需 key 层（注册免费）──
    /// 智谱 GLM。免费视觉模型 glm-4.6v-flash（dsh-vision/README:28）
    case zhipu
    /// Groq（免费额度，低延迟）
    case groq
    /// OpenRouter（免费档 15 个模型）
    case openRouter

    // ── 自定义 ──
    /// 用户自定义的任意 OpenAI 兼容端点
    case userKey

    /// 是否需要 API Key 才能使用
    var requiresKey: Bool {
        switch self {
        case .ovhAnonymous, .zenFree, .pollinations, .pollinationsLegacy:
            return false
        case .zhipu, .groq, .openRouter, .userKey:
            return true
        }
    }

    /// 是否属于「免 key 层」（UI 置灰逻辑与向导第 1 步用）
    var isKeyless: Bool { !requiresKey }

    /// 展示名（UI 小字与向导）
    var displayName: String {
        switch self {
        case .ovhAnonymous:       return "OVHcloud 匿名"
        case .zenFree:            return "OpenCode Zen"
        case .pollinations:       return "Pollinations"
        case .pollinationsLegacy: return "Pollinations 旧"
        case .zhipu:              return "智谱 GLM"
        case .groq:               return "Groq"
        case .openRouter:         return "OpenRouter"
        case .userKey:            return "自定义端点"
        }
    }

    /// 风险声明（设置页与小字 tooltip 如实展示）。
    ///
    /// 用户明确要求：**免费渠道的失效风险必须如实告知**，
    /// 不能让用户以为"免费"是稳定承诺。
    var riskNote: String {
        switch self {
        case .ovhAnonymous:
            return "免注册免 key。匿名配额为 2 请求/分钟/IP/模型，可能限流；"
                 + "对话内容与截图会发送到 OVHcloud 服务器。"
        case .zenFree:
            return "免注册免 key（走 OpenCode 免费档）。官方随时可能收紧门禁"
                 + "（实测 14 个免费模型仅 1 个存活），对话内容与截图会发送到第三方。"
        case .pollinations:
            return "免注册免 key。共享容量池，高峰期可能限流；"
                 + "仅支持纯文本（图片请求需要 key）。"
        case .pollinationsLegacy:
            return "免注册免 key 的兜底渠道，仅单模型、能力有限。"
        case .zhipu:
            return "需注册（免费）。glm-4.6v-flash 为免费视觉模型，公共容量池偶发 429。"
        case .groq:
            return "需注册（有免费额度）。低延迟，适合实时对话。"
        case .openRouter:
            return "需注册（免费档）。免费模型可用性波动较大。"
        case .userKey:
            return "使用你自己填写的端点与密钥，数据只经过你指定的服务商。"
        }
    }
}

// MARK: - 模型能力描述

/// 单个模型的能力与元数据（供 UI 徽章、候选过滤、视觉门控使用）
struct LLMModelInfo: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var supportsVision: Bool
    var supportsTools: Bool
    var isFree: Bool
    var contextLength: Int?

    init(id: String, displayName: String? = nil, supportsVision: Bool = false,
         supportsTools: Bool = true, isFree: Bool = false, contextLength: Int? = nil) {
        self.id = id
        self.displayName = displayName ?? id
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.isFree = isFree
        self.contextLength = contextLength
    }
}

// MARK: - AI 助手配置

/// AI 面板配置（API Key / 模型 / 端点）——用户自己填写，存本地 0600 小本本。
///
/// 【兼容性】本结构体由 AIAgentPanel.swift:81 抽出（2026-10-06 W0 接口冻结）。
/// 字段 `apiKey/baseUrl/model/thinkingDepth` 的语义与持久化格式**保持不变**，
/// 新增字段全部带默认值，旧配置读入后自动获得新默认值。
struct AgentSettings: Codable, Sendable {
    // ── 既有字段（语义与格式不变）──
    var apiKey: String = ""
    var baseUrl: String = "https://api.deepseek.com"
    var model: String = "deepseek-chat"
    var thinkingDepth: Int = 1  // 1-4: 低Low/中Mid/高High/极致Max，映射到 temperature

    // ── 新增字段（2026-10-06，全部带默认值）──
    /// 当前后端渠道。默认免 key 的 OVHcloud 匿名层（用户零配置即可对话）。
    var backendKind: LLMBackendKind = .ovhAnonymous
    /// 是否允许自动降级到渠道链上的其他模型
    var fallbackEnabled: Bool = true
    /// 是否允许把截图发给模型（隐私开关，**默认关闭**）
    var visionEnabled: Bool = false
    /// 免 key 渠道下的首选模型（空 = 由健康监控自动挑）
    var preferredFreeModel: String = ""
    /// 用户显式启用的渠道集合（UI 勾选；空 = 只启用免 key 层）
    var enabledBackends: [LLMBackendKind] = []

    // ── 持久化（格式与原实现逐字兼容）──

    static let service = "com.aurora.drive.aiagent"
    static let keyApi = "apiKey"
    static let keyBase = "baseUrl"
    static let keyModel = "model"
    static let keyDepth = "thinkingDepth"
    // 新增键
    static let keyBackend = "backendKind"
    static let keyFallback = "fallbackEnabled"
    static let keyVision = "visionEnabled"
    static let keyPreferredFree = "preferredFreeModel"
    static let keyEnabledBackends = "enabledBackends"

    /// 固定 suite 的 UserDefaults（CLI 与 .app 共用同一份，避免进程名不同域不同）
    static let suiteName = "com.aurora.drive.aiagent"
    static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// API Key「小本本」文件（用户指令：不再访问钥匙串——启动路径每次读 Keychain 是启动异常根因；
    /// 改存用户目录 0600 文件，启动路径零 Keychain 接触）
    static var notebookURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AuroraDrive", isDirectory: true)
        return dir.appendingPathComponent("llm-key-notebook.txt")
    }

    /// 保存（API Key → 本地小本本文件 0600；非敏感字段 → 固定域 UserDefaults；全程不碰钥匙串）
    func save() throws {
        // 非敏感字段存固定域 UserDefaults（与进程名无关，CLI 与 GUI 共用）
        let d = AgentSettings.defaults
        d.set(baseUrl, forKey: AgentSettings.keyBase)
        d.set(model, forKey: AgentSettings.keyModel)
        d.set(thinkingDepth, forKey: AgentSettings.keyDepth)
        // 新增字段
        d.set(backendKind.rawValue, forKey: AgentSettings.keyBackend)
        d.set(fallbackEnabled, forKey: AgentSettings.keyFallback)
        d.set(visionEnabled, forKey: AgentSettings.keyVision)
        d.set(preferredFreeModel, forKey: AgentSettings.keyPreferredFree)
        d.set(enabledBackends.map(\.rawValue), forKey: AgentSettings.keyEnabledBackends)
        d.synchronize()
        guard !apiKey.isEmpty else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: AgentSettings.notebookURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try (apiKey.data(using: .utf8) ?? Data()).write(to: AgentSettings.notebookURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AgentSettings.notebookURL.path)
    }

    /// 从本地小本本加载（不碰钥匙串）
    static func load() -> AgentSettings {
        var settings = AgentSettings()
        // 读取 apiKey（本地小本本文件）
        if let data = try? Data(contentsOf: notebookURL),
           let key = String(data: data, encoding: .utf8), !key.isEmpty {
            settings.apiKey = key
        }
        // 读取非敏感字段（固定域）
        let d = AgentSettings.defaults
        settings.baseUrl = d.string(forKey: keyBase) ?? settings.baseUrl
        settings.model = d.string(forKey: keyModel) ?? settings.model
        settings.thinkingDepth = d.integer(forKey: keyDepth)
        if settings.thinkingDepth < 1 { settings.thinkingDepth = 3 }

        // 新增字段（缺省时保留结构体默认值 → 旧配置自动升级）
        if let raw = d.string(forKey: keyBackend),
           let kind = LLMBackendKind(rawValue: raw) {
            settings.backendKind = kind
        }
        if d.object(forKey: keyFallback) != nil {
            settings.fallbackEnabled = d.bool(forKey: keyFallback)
        }
        settings.visionEnabled = d.bool(forKey: keyVision)   // 缺省 false（隐私默认）
        settings.preferredFreeModel = d.string(forKey: keyPreferredFree) ?? ""
        if let raws = d.array(forKey: keyEnabledBackends) as? [String] {
            settings.enabledBackends = raws.compactMap { LLMBackendKind(rawValue: $0) }
        }
        return settings
    }

    /// 删除本地小本本中的 API Key（函数名保留兼容，不再碰钥匙串）
    static func deleteKeychain() {
        try? FileManager.default.removeItem(at: notebookURL)
    }

    /// 有效渠道集合：用户显式启用的渠道；若为空则只启用**免 key 层**。
    ///
    /// 【用户规格】未配置 API Key 时只能用免 key 层；配置后才允许选需 key 渠道。
    var effectiveBackends: [LLMBackendKind] {
        let configured = enabledBackends.isEmpty
            ? LLMBackendKind.allCases.filter(\.isKeyless)
            : enabledBackends
        guard apiKey.isEmpty else { return configured }
        // 无 key：过滤掉需 key 渠道
        return configured.filter(\.isKeyless)
    }

    /// 当前渠道是否可用（无 key 时需 key 渠道不可用）
    var currentBackendUsable: Bool {
        apiKey.isEmpty ? backendKind.isKeyless : true
    }
}
