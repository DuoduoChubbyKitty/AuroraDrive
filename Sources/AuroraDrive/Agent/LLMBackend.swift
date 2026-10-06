// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  LLMBackend.swift — 多渠道后端抽象（W1 · task-1 · 2026-10-06）
// ============================================================================
//
//  【职责边界】本文件只回答三个问题：
//    ① 有哪些渠道（LLMBackendDescriptor）
//    ② 每个渠道怎么建一条合法请求（makeRequest）
//    ③ 每个渠道有哪些模型、各自什么能力（models / staticModels）
//  它**不发送请求**（W2 LLMTransport.swift），**不做健康监控与降级排序**
//  （W3 LLMHealth.swift），**不碰 UI**（W6 AIAgentPanel.swift）。
//
//  【接口依赖】LLMMessage / LLMToolSpec / LLMImage / LLMRole 由 W2
//  （LLMTransport.swift）定义，本文件只引用、**不重复定义**（重复符号会全模块红）。
//
//  【对外契约】由 Lead 冻结 + W3/W7 已落盘的**实际调用点**共同确定（2026-10-06 21:2x）：
//    · W3 LLMHealth.swift:1313   `LLMBackendRegistry.shared.descriptor(for:)` → 可空
//    · W3 LLMHealth.swift:1157   `LLMBackendRegistry.shared.provider(for:apiKey:)` → 可空
//    · W3 LLMHealth.swift:1158   `try? await provider.models(apiKey:)` → **可抛**
//    · W7 AgentLoop.swift:510    `LLMBackendRegistry.shared.descriptor(for:)`
//    · W7 AgentLoop.swift:520    `descriptor?.extraHeaders`（Zen 三头从这里取）
//    · W3/W7 只访问描述符 4 个成员：baseURL / extraHeaders / staticModels（+ kind）
//  因此本文件**保留了比最小契约更完整的字段**（多出的字段不影响既有调用点编译）。
//
//  【红线】本文件不硬编码任何 API Key。唯一出现的字面量 "public" 是 OpenCode Zen
//  公开档的**哨兵值**，不是凭据（出处 /tmp/zen-proxy.mjs:495 `return "Bearer public"`）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  【实测数据出处】2026-10-06 21:18–21:35（Asia/Shanghai），现场 curl 真端点。
//    命令 → 结果（原始输出已存档 /tmp/w1_*.json）：
//    · OVH      GET  /v1/models              → 200 · 24 条（**无需 Authorization 头**）
//               POST /chat/completions       → 200（Qwen3.6-27B）
//                                             429 "API rate limit exceeded"（其余 4 桶）
//    · Zen      GET  /v1/models              → 200 · 86 条（三头任意缺失仍 200）
//               POST /chat/completions       → 200 + **tool_calls 正常**
//                                             付费模型（claude-sonnet-5/gpt-5.5）→ 401
//    · Gen      GET  /v1/models              → 200 · 298 条
//               POST /chat/completions       → **401 要 key（本机 9 次实测；见下）**
//    · Legacy   GET  /models                 → 200 · 单条 openai-fast
//               POST /openai/chat/completions→ 200（**注意：base 本身即 chat 端点**）
//    · OpenRouter GET /api/v1/models         → 200 · 464 条（公开可读）
//    · Groq     GET  /openai/v1/models       → 403 Forbidden（要 key）
//    · 智谱     GET  /api/paas/v4/models     → 401 code 1001（要 key）
//
//  【⚠️ 关于 pollinations 免 key 的观测冲突 —— 双方证据都在，故不作确定性断言】
//    本机实测（2026-10-06 21:18–21:45，共 9 次，含不带额外头 / 浏览器 UA+Referer /
//    `?referrer=` / `?token=anonymous` / `Authorization: Bearer anonymous` / stream:true）：
//      gen.pollinations.ai POST /v1/chat/completions 对 openai、openai/gpt-5.4-nano、
//      mistralai/mistral-large-3、community/tomdacatto/llama-3.1-8B **全部 401**：
//        {"success":false,"error":{"message":"A valid API key is required.
//         Get one at https://enter.pollinations.ai/keys","code":"UNAUTHORIZED"}}
//      全程**未出现 429**；同一时刻 Legacy 端点 200、gen 的 GET /v1/models 也 200。
//    Lead 复测（4 次，含 max_tokens/stream）**均成功返回**。
//    → 结论：这是**时段性门禁波动**，非永久门禁亦非限流。故：
//      · 按 Lead 裁决保留 requiresKey=false（不擅自改冻结契约）
//      · riskNote 只陈述"存在波动、以探活为准"，**不写死"要 key"也不写"限流"**
//      · 真正的可用性判定交给 W3 LLMHealthMonitor 探活（它按真实请求结果定健康态）
// ============================================================================

import Foundation

// MARK: - 错误

/// 建请求阶段的错误（**只覆盖本地校验**；网络/上游错误分类由 W2 LLMError 负责）。
enum LLMBackendError: Error, LocalizedError, Equatable {
    /// baseURL 或拼接后的端点不是合法 URL
    case invalidBaseURL(String)
    /// 该渠道需要 key，但调用方给了空 key
    case missingAPIKey(LLMBackendKind)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let raw):
            return "无效的端点地址：\(raw)"
        case .missingAPIKey(let kind):
            return "\(kind.displayName) 需要 API Key（当前为空），请先在设置里配置"
        }
    }
}

// MARK: - 渠道描述符

/// 单个渠道的静态描述：端点、鉴权要求、特殊头、备用模型表。
///
/// 【为什么 baseURL 之外还要存两个完整 URL】
///   实测发现两种端点形状，**不能统一用「base + /chat/completions」推导**：
///     · Legacy：base = https://text.pollinations.ai/openai
///               chat  = {base}/chat/completions（实测 POST 该路径 200）
///               models = https://text.pollinations.ai/models（**不在 base 下**，
///                        实测 200 / 286 字节 / 返回裸数组而非 {"data":[...]}）
///   所以两个完整 URL 都**按实测显式写死**，避免任何隐式拼接魔法。
struct LLMBackendDescriptor: Sendable, Equatable {
    /// 渠道种类（与 AgentSettings.LLMBackendKind 一一对应）
    let kind: LLMBackendKind
    /// 展示名（取自冻结的 LLMBackendKind.displayName，单一事实来源）
    let displayName: String
    /// 渠道根地址（含 /v1 等路径前缀，已按实测填写）
    let baseURL: String
    /// 是否必须 API Key（取自冻结的 LLMBackendKind.requiresKey）
    let requiresKey: Bool
    /// 风险声明（取自冻结的 LLMBackendKind.riskNote，UI 如实展示）
    let riskNote: String
    /// 必须注入的额外请求头（如 Zen 三头）。空 = 不加任何特殊头。
    /// **W7 AgentLoop.swift:520 从这里取 Zen 三头交给 W2 传输层。**
    let extraHeaders: [String: String]
    /// 静态备用模型表：**顺序有意义**（OVH 即大到小轮转表；W3 依赖该顺序降级）。
    /// **W3 LLMHealth.swift:903/969/1219 直接读这张表**——故能力标志必须在此就准确。
    let staticModels: [LLMModelInfo]
    /// chat/completions 完整端点（实测显式填写）
    let chatCompletionsURLString: String
    /// 模型清单完整端点（实测显式填写）
    let modelsURLString: String
    /// 运行时模型清单的过滤策略
    let modelPolicy: LLMBackendModelPolicy
    /// 该渠道的「视觉」是否额外需要 key（true 时运行时拉取也强制 supportsVision=false）
    let visionRequiresKey: Bool
    /// 请求体 max_tokens（OVH 参考实现用 4096，见 core-primitives.js:1780）
    let maxTokens: Int

    var chatCompletionsURL: URL? { URL(string: chatCompletionsURLString) }
    var modelsURL: URL? { URL(string: modelsURLString) }

    /// 该渠道「零配置可用」还是「需要注册」——UI 置灰与向导用
    var isKeyless: Bool { !requiresKey }
}

/// 运行时拉到的模型清单如何过滤（不同渠道的 /models 语义不同）
enum LLMBackendModelPolicy: Sendable, Equatable {
    /// 全部接受
    case all
    /// Zen 免费档：**仅 `-free` 结尾的模型可用**。
    /// 实测：/v1/models 返回 86 条（含 claude/gpt/gemini 全系），但用 `Bearer public`
    /// 打 claude-sonnet-5、gpt-5.5 → 401 AuthError "Missing API key."；
    /// space-bunny-free → 200。故静态表只留实测存活的那个，运行时也只认 -free。
    case zenFreeSuffixOnly
    /// 排除非对话模型（embedding / rerank / tts / whisper / 图像生成 / 内容审核分类器）
    case chatModelsOnly
}

// MARK: - Provider 协议

/// 渠道提供方：描述符 + 拉模型 + 建请求。
///
/// 全部方法 **nonisolated / async**，不触碰主线程（性能红线）。
/// `makeRequest` 只做本地组装（不发网络），网络由 W2 的 LLMTransport 负责。
protocol LLMBackendProvider: Sendable {
    /// 该渠道的静态描述
    var descriptor: LLMBackendDescriptor { get }

    /// 运行时拉取模型清单（GET {modelsURL}）。
    ///
    /// 【契约】声明为 `throws` 以匹配 W3 LLMHealth.swift:1158 的 `try? await`；
    /// 但**实现永不抛错**——网络失败/解析失败/上游异常一律回退 `descriptor.staticModels`。
    /// 理由：调用方（W3 探活、W6 UI）需要一个「总能用」的清单；失败信息由健康态承载。
    /// - Parameter apiKey: nil 或空串表示免 key 渠道（不带 Authorization 头）。
    /// - Returns: 策展表在前、运行时新增项在后（保证 OVH 轮转顺序不被网络返回打乱）。
    func models(apiKey: String?) async throws -> [LLMModelInfo]

    /// 组装一条 OpenAI 兼容的请求（不发网络）。
    /// - Parameters:
    ///   - model: 模型 id
    ///   - messages: W2 的 LLMMessage（复用其 openAIDictionary() 编码，避免两份实现不一致）
    ///   - tools: W2 的 LLMToolSpec（空数组则不写 tools 字段）
    ///   - stream: true 时写 "stream": true，并期待 SSE 响应（解析在 W2）
    ///   - apiKey: 空串 = 免 key 渠道
    func makeRequest(model: String, messages: [LLMMessage], tools: [LLMToolSpec],
                     stream: Bool, apiKey: String) throws -> URLRequest
}

// MARK: - 共用的 HTTP / 解析工具

/// 模型清单拉取与解析（渠道无关的通用部分）。
enum LLMBackendHTTP {
    /// 独立 URLSession：**不与 captureQueue / aurora.quest.ocr 共用**（性能红线）。
    /// 探活请求超时 8s（W3 规格），清单拉取宽限到 10s。
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// GET 一个 JSON 端点。失败返回 nil（调用方回退静态表）。
    static func getJSON(url: URL, headers: [String: String], timeout: TimeInterval = 10) async -> Any? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return nil
        }
    }

    /// 解析两种实测过的清单形状：
    ///   ① `{"object":"list","data":[{...}]}` —— OVH / gen / Zen / OpenRouter
    ///   ② `[{...}]` 裸数组 —— Legacy（实测 text.pollinations.ai/models，286 字节）
    /// 字段名两种都有：`id` 或 `name`。
    static func parseModelList(_ payload: Any) -> [[String: Any]] {
        if let dict = payload as? [String: Any], let rows = dict["data"] as? [[String: Any]] {
            return rows
        }
        if let rows = payload as? [[String: Any]] {
            return rows
        }
        return []
    }

    /// 单个条目 → LLMModelInfo（缺字段一律保守取值：不支持而非假装支持）。
    static func modelInfo(from row: [String: Any]) -> LLMModelInfo? {
        let id = (row["id"] as? String) ?? (row["name"] as? String)
        guard let id, !id.isEmpty else { return nil }

        // 视觉：gen/Zen 用 input_modalities:["text","image"]；OpenRouter 用 architecture.input_modalities
        var modalities = row["input_modalities"] as? [String]
        if modalities == nil,
           let arch = row["architecture"] as? [String: Any] {
            modalities = arch["input_modalities"] as? [String]
        }
        let vision = modalities?.contains("image") ?? false

        // 工具：Legacy 用裸布尔 tools；gen 用 capabilities/tools 组合
        var tools = false
        if let flag = row["tools"] as? Bool {
            tools = flag
        } else if let caps = row["capabilities"] as? [String] {
            tools = caps.contains("tool_calling")
        }

        // 上下文长度（OVH 用 context_length；OpenRouter 用 context_length 或 top_provider）
        var ctx = row["context_length"] as? Int
        if ctx == nil, let top = row["top_provider"] as? [String: Any] {
            ctx = top["context_length"] as? Int
        }

        return LLMModelInfo(id: id,
                            supportsVision: vision,
                            supportsTools: tools,
                            isFree: true,          // 免 key 渠道默认免费；需 key 渠道"免费额度"由 UI 另行标注
                            contextLength: (ctx ?? 0) > 0 ? ctx : nil)
    }

    /// 是否像「对话模型」——用于 OVH 这类混装了 embedding/tts/whisper/绘图模型的清单。
    ///
    /// 实测依据（OVH /v1/models 24 条）：
    ///   · 非对话模型 `context_length` 全为 0（stable-diffusion-xl、nvr-tts-*、whisper-*）
    ///   · 嵌入模型 bge-m3 / bge-multilingual-gemma2 / Qwen3-Embedding-8B 有 ctx 但非对话
    ///   · Qwen3Guard-* 是内容审核分类器（ctx 非 0），不能当对话模型用
    static func looksLikeChatModel(id: String, row: [String: Any]) -> Bool {
        let ctx = (row["context_length"] as? Int) ?? -1
        if ctx == 0 { return false }
        let lower = id.lowercased()
        let nonChat = ["embedding", "bge-", "rerank", "tts", "whisper", "stable-diffusion", "guard"]
        return !nonChat.contains(where: { lower.contains($0) })
    }
}

// MARK: - 模型目录（实测策展表）

/// 各渠道的静态模型表（**全部来自 2026-10-06 现场实测**）。
enum LLMModelCatalog {

    // ────────────────────────────────────────────────────────────────────────
    // OVHcloud 匿名层：5 模型轮转表
    //   **顺序照抄** dsh-vision-router/src/lib/core-primitives.js:1779-1788
    //   （注释原文：anonymous quota is per IP AND per model. Keep the free chain
    //    ordered largest -> smallest so quality wins first. A 429 on one model can
    //    immediately fall through to the next model's independent anonymous bucket.）
    //   实测核对：GET /v1/models 中 5 个 id **全部存在**，context_length 如下。
    //   实测限流：本轮 6 次请求后，4 个桶 429、仅 Qwen3.6-27B 返回 200
    //   → 印证「per IP AND per model」：桶是独立的，429 可切隔壁桶。
    // ────────────────────────────────────────────────────────────────────────
    static let ovhRotation: [LLMModelInfo] = [
        LLMModelInfo(id: "Qwen3.5-397B-A17B", supportsVision: false, supportsTools: true,
                     isFree: true, contextLength: 262144),
        // 视觉：id 含 VL，实测 /v1/models context_length=32768
        LLMModelInfo(id: "Qwen2.5-VL-72B-Instruct", supportsVision: true, supportsTools: true,
                     isFree: true, contextLength: 32768),
        LLMModelInfo(id: "Qwen3.6-27B", supportsVision: false, supportsTools: true,
                     isFree: true, contextLength: 262144),
        LLMModelInfo(id: "Mistral-Small-3.2-24B-Instruct-2506", supportsVision: false, supportsTools: true,
                     isFree: true, contextLength: 131072),
        LLMModelInfo(id: "Qwen3.5-9B", supportsVision: false, supportsTools: true,
                     isFree: true, contextLength: 262144),
    ]

    // ────────────────────────────────────────────────────────────────────────
    // Pollinations（gen.pollinations.ai）：37 个文本模型
    //   数据来源：GET https://gen.pollinations.ai/v1/models → 200 · 298 条，
    //   本表 37 个 id **逐个实测核对存在**（canonical id 或 aliases 命中）。
    //   tools / ctx 两列取自该响应自身字段（实测值，非推测）：
    //     tools ← tools==true 或 capabilities 含 "tool_calling"
    //     ctx   ← context_length
    //
    //   ⚠️ supportsVision **一律 false** —— 依 task-1 描述「图片请求该渠道要 key」，
    //      且 Lead 冻结明确「Pollinations 全部 = false」。W3 直接读这张静态表，
    //      故必须在此就压平，不能只靠运行时 visionRequiresKey 兜底。
    //      以下注释保留**实测的 input_modalities 事实**备查（哪些模型上游其实能看图的）：
    //        image 能力为真的是（实测 input_modalities 含 image，但本渠道要 key → 不可用）：
    //        openai, openai-fast, openai/gpt-5.4-nano, openai/gpt-5-nano,
    //        openai/gpt-5.4-mini, openai/gpt-5.4, openai/gpt-5.5, x-ai/grok-4.6,
    //        x-ai/grok-4.3, x-ai/grok-4.20, moonshotai/kimi-k3, moonshotai/kimi-k2.6,
    //        deepseek/deepseek-v4.1-flash, z-ai/glm-5.3-flash, minimax/minimax-m3,
    //        mistralai/mistral-large-3, cohere/command-a-plus, amazon/nova-2-lite-v1,
    //        qwen/qwen3.8-2.4t-a95b, pollinations/midijourney,
    //        pollinations/midijourney-large, community/pegalink/gemini-3.5-flash-lite,
    //        community/MarcosFRG/glm-5.3-flash
    //      注：`openai` / `openai-fast` 是别名（aliases 分别挂在
    //          openai/gpt-5.4-nano 与 openai/gpt-5-nano 上，实测确认）。
    // ────────────────────────────────────────────────────────────────────────
    static let pollinations: [LLMModelInfo] = [
        // id, tools, ctx（supportsVision 固定 false，理由见上）
        mk("openai", true, 400_000),
        mk("openai-fast", true, 400_000),
        mk("openai/gpt-5.4-nano", true, 400_000),
        mk("openai/gpt-5-nano", true, 400_000),
        mk("openai/gpt-5.4-mini", true, 400_000),
        mk("openai/gpt-5.4", true, 1_050_000),
        mk("openai/gpt-5.5", true, 1_050_000),
        mk("openai/gpt-oss-20b", true, 131_072),
        mk("x-ai/grok-4.6", true, 200_000),
        mk("x-ai/grok-4.3", true, 200_000),
        mk("x-ai/grok-4.20", true, 262_144),
        mk("moonshotai/kimi-k3", true, 1_048_576),
        mk("moonshotai/kimi-k2.6", true, 262_000),
        mk("deepseek/deepseek-v4.1-flash", true, 1_048_576),
        mk("deepseek/deepseek-v4-flash", true, 1_048_576),
        mk("z-ai/glm-5.3", true, 1_048_576),
        mk("z-ai/glm-5.3-flash", true, 1_048_576),          // 实测 health=degraded
        mk("z-ai/glm-5.2", true, 1_048_576),
        mk("minimax/minimax-m3", true, 524_288),            // 实测 health=degraded
        mk("mistralai/mistral-large-3", true, 256_000),
        mk("cohere/command-a-plus", true, 128_000),
        mk("amazon/nova-2-lite-v1", true, 1_048_576),       // 实测 health=degraded
        mk("amazon/nova-micro-v1", true, 128_000),
        mk("meta/llama-3.3-70b-instruct", true, 131_072),
        mk("qwen/qwen3.8-2.4t-a95b", true, 262_144),
        mk("qwen/qwen3-coder-30b-a3b-instruct", true, 262_144),
        mk("qwen/qwen3guard-gen-8b", false, nil),           // 实测 tools=false，审核分类器
        mk("nvidia/nemotron-3.5-lightning", true, 262_144),
        mk("inclusionai/ling-3.1-flash", true, 262_144),    // 实测 health=down
        mk("pollinations/midijourney", true, nil),
        mk("pollinations/midijourney-large", true, nil),
        mk("community/pegalink/gemini-3.5-flash-lite", true, 1_000_000),
        mk("community/gggff123/gpt-5-nano", false, nil),    // 实测 tools=false
        mk("community/JustScriptzz/gpt-oss-120b", true, 131_072),
        mk("community/MarcosFRG/glm-5.3-flash", true, 1_048_576),
        mk("community/Catniti/nemotron-3.5-lightning", true, nil),
        mk("community/tomdacatto/llama-3.1-8B", false, nil), // 实测 tools=false
    ]

    // ────────────────────────────────────────────────────────────────────────
    // OpenCode Zen 免费档
    //   实测：GET /v1/models → 200 · 86 条；用 `Bearer public` 打 chat：
    //     space-bunny-free → 200（并且 **tool_calls 正常返回**）
    //     付费模型（claude-sonnet-5 / gpt-5.5）→ 401 AuthError "Missing API key."
    //   故静态表只留实测存活且**具备视觉**的那个，其余交给运行时 -free 过滤。
    //   视觉来源：task-1 描述「space-bunny-free（视觉）」；本轮未单独构造图片请求复验
    //   → 标「描述给定、未复验」。
    // ────────────────────────────────────────────────────────────────────────
    static let zenFree: [LLMModelInfo] = [
        LLMModelInfo(id: "space-bunny-free", supportsVision: true, supportsTools: true,
                     isFree: true, contextLength: nil),
    ]

    // ────────────────────────────────────────────────────────────────────────
    // Pollinations Legacy（text.pollinations.ai）
    //   实测：GET /models → 200，返回裸数组单条：
    //     {"name":"openai-fast","description":"GPT-OSS 20B Reasoning LLM (OVH)",
    //      "reasoning":true,"tools":true,"vision":false,...}
    //   → tools=true、vision=false 均为实测字段值。
    // ────────────────────────────────────────────────────────────────────────
    static let pollinationsLegacy: [LLMModelInfo] = [
        LLMModelInfo(id: "openai-fast", supportsVision: false, supportsTools: true,
                     isFree: true, contextLength: nil),
    ]

    // ────────────────────────────────────────────────────────────────────────
    // 智谱 GLM（需 key）
    //   视觉清单来自 task-1 描述 + dsh-vision/README:28（glm-4.6v-flash 免费视觉）。
    //   本轮**无 key 未实测**（GET /models → 401 code 1001）→ 全部标「未验证」。
    //   降级顺序照抄描述：glm-4.6v-flash → glm-4.1v-thinking-flash → glm-4v-flash。
    // ────────────────────────────────────────────────────────────────────────
    static let zhipu: [LLMModelInfo] = [
        LLMModelInfo(id: "glm-4.6v-flash", supportsVision: true, supportsTools: true,
                     isFree: true, contextLength: nil),          // 未验证（无 key）
        LLMModelInfo(id: "glm-4.1v-thinking-flash", supportsVision: true, supportsTools: true,
                     isFree: true, contextLength: nil),          // 未验证（无 key）· 降级项
        LLMModelInfo(id: "glm-4v-flash", supportsVision: true, supportsTools: true,
                     isFree: true, contextLength: nil),          // 未验证（无 key）· 降级项
    ]

    /// Pollinations 表专用构造：supportsVision **强制 false**（渠道图片请求要 key）
    private static func mk(_ id: String, _ tools: Bool, _ ctx: Int?) -> LLMModelInfo {
        LLMModelInfo(id: id, supportsVision: false, supportsTools: tools, isFree: true, contextLength: ctx)
    }
}

// MARK: - 各渠道实现

/// 免 key 渠道的公共基类行为：不带 Authorization 头（实测 OVH 无 Authorization → 200）。
private func baseHeaders(for descriptor: LLMBackendDescriptor,
                         apiKey: String,
                         stream: Bool) -> [String: String] {
    var headers: [String: String] = [
        "Content-Type": "application/json",
        // 出处 /tmp/zen-proxy.mjs:468 `accept: "application/json, text/event-stream"`
        "Accept": stream ? "application/json, text/event-stream" : "application/json",
    ]
    // 渠道自带的固定头（Zen 三头）优先落地
    for (k, v) in descriptor.extraHeaders { headers[k] = v }
    // Authorization 规则：
    //   · 显式给了 key → Bearer <key>
    //   · Zen 免费档 → 保持 extraHeaders 里的 "Bearer public"（公开哨兵，非凭据）
    //   · 其余免 key 渠道 → **不加该头**（实测 OVH 无此头可 200；空 "Bearer " 无意义）
    if !apiKey.isEmpty {
        headers["Authorization"] = "Bearer \(apiKey)"
    }
    return headers
}

/// 组装 URLRequest 的公共实现（各渠道差异全部由 descriptor 决定）。
private func buildRequest(descriptor: LLMBackendDescriptor,
                          model: String,
                          messages: [LLMMessage],
                          tools: [LLMToolSpec],
                          stream: Bool,
                          apiKey: String) throws -> URLRequest {
    if descriptor.requiresKey && apiKey.isEmpty {
        throw LLMBackendError.missingAPIKey(descriptor.kind)
    }
    guard let url = descriptor.chatCompletionsURL else {
        throw LLMBackendError.invalidBaseURL(descriptor.chatCompletionsURLString)
    }

    var body: [String: Any] = [
        "model": model,
        // 复用 W2 的编码助手（单一实现，避免两边 body 形状漂移）
        "messages": messages.map { $0.openAIDictionary() },
        "stream": stream,
        // OVH 参考实现用 4096（core-primitives.js:1780 maxTokens: 4096）
        "max_tokens": descriptor.maxTokens,
    ]
    if !tools.isEmpty {
        body["tools"] = tools.map { $0.openAIDictionary() }
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    for (key, value) in baseHeaders(for: descriptor, apiKey: apiKey, stream: stream) {
        request.setValue(value, forHTTPHeaderField: key)
    }
    // 流式给更宽的本地超时；非流式 60s。真正的中断/分类由 W2 负责。
    request.timeoutInterval = stream ? 120 : 60
    return request
}

/// 拉模型的公共实现：GET {modelsURL} → 解析 → **策展表在前、运行时新增在后**。
/// **永不抛错**（协议声明 throws 只为匹配 W3 的 `try?` 调用形状）。
private func fetchModels(descriptor: LLMBackendDescriptor, apiKey: String?) async -> [LLMModelInfo] {
    let key = apiKey ?? ""
    guard !(descriptor.requiresKey && key.isEmpty), let url = descriptor.modelsURL else {
        return descriptor.staticModels
    }
    var headers = descriptor.extraHeaders
    if !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
    guard let payload = await LLMBackendHTTP.getJSON(url: url, headers: headers),
          !LLMBackendHTTP.parseModelList(payload).isEmpty else {
        return descriptor.staticModels     // 失败/空 → 回退静态表（契约：永不抛错）
    }

    let rows = LLMBackendHTTP.parseModelList(payload)

    // ① 策展表（含实测能力覆盖 + 顺序）原样保留
    var result = descriptor.staticModels
    var seen = Set(result.map(\.id))
    // 视觉需 key 的渠道：策展表也压平
    if descriptor.visionRequiresKey {
        result = result.map {
            var m = $0; m.supportsVision = false; return m
        }
    }

    // ② 运行时新增项追加在后（**不打乱策展顺序**——OVH 轮转表顺序是 W3 的依赖）
    for row in rows {
        guard let info = LLMBackendHTTP.modelInfo(from: row) else { continue }
        guard !seen.contains(info.id) else { continue }
        switch descriptor.modelPolicy {
        case .all:
            break
        case .zenFreeSuffixOnly:
            guard info.id.hasSuffix("-free") else { continue }
        case .chatModelsOnly:
            guard LLMBackendHTTP.looksLikeChatModel(id: info.id, row: row) else { continue }
        }
        var info2 = info
        if descriptor.visionRequiresKey { info2.supportsVision = false }
        result.append(info2)
        seen.insert(info2.id)
    }
    return result.isEmpty ? descriptor.staticModels : result
}

// ── ① OVHcloud 匿名 ─────────────────────────────────────────────────────────

/// OVHcloud AI Endpoints 匿名层（免注册免 key，视觉可用）。
/// 配额 per IP AND per model（出处 core-primitives.js:1780-1782）→ 429 可切下一模型桶。
struct OVHAnonymousProvider: LLMBackendProvider {
    let descriptor = LLMBackendDescriptor(
        kind: .ovhAnonymous,
        displayName: LLMBackendKind.ovhAnonymous.displayName,
        baseURL: "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1",
        requiresKey: false,
        riskNote: LLMBackendKind.ovhAnonymous.riskNote,
        extraHeaders: [:],                       // 实测：无任何特殊头
        staticModels: LLMModelCatalog.ovhRotation,
        chatCompletionsURLString: "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1/chat/completions",
        modelsURLString: "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1/models",
        modelPolicy: .chatModelsOnly,            // 实测 24 条里混了 embedding/tts/whisper/绘图
        visionRequiresKey: false,
        maxTokens: 4096
    )
    func models(apiKey: String?) async throws -> [LLMModelInfo] {
        await fetchModels(descriptor: descriptor, apiKey: apiKey)
    }
    func makeRequest(model: String, messages: [LLMMessage], tools: [LLMToolSpec],
                     stream: Bool, apiKey: String) throws -> URLRequest {
        try buildRequest(descriptor: descriptor, model: model, messages: messages,
                         tools: tools, stream: stream, apiKey: apiKey)
    }
}

// ── ② OpenCode Zen 免费档 ───────────────────────────────────────────────────

/// OpenCode Zen 免费档（必须三头注入）。
///
/// 三头出处 /tmp/zen-proxy.mjs `zenHeaders()`（:465-481）：
///   user-agent: config.ua  → 实测取 opencode/1.18.30
///   x-opencode-session: sess.value（sess_<26位hex>）
///   authorization: 免费档兜底 "Bearer public"（:495）
/// 会话值**每个 provider 实例生成一次并稳定复用**（规格要求）；
/// 由 LLMBackendRegistry.shared 持有单例 → 全进程同一个 session。
/// 实测补注：本轮去掉 UA 或 session 单头仍返回 200 —— 即上游目前不强校验；
/// 但按规格照抄实现，为上游收紧门禁预留正确形状。
struct ZenFreeProvider: LLMBackendProvider {
    /// 仅在实例创建时生成一次 → 同一实例的全部请求复用同一 session
    let sessionID: String

    init(sessionID: String? = nil) {
        self.sessionID = sessionID ?? ZenFreeProvider.makeSessionID()
    }

    /// `ses_` + 26 位小写 hex（13 随机字节）
    static func makeSessionID() -> String {
        var bytes = [UInt8](repeating: 0, count: 13)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return "ses_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    var descriptor: LLMBackendDescriptor {
        LLMBackendDescriptor(
            kind: .zenFree,
            displayName: LLMBackendKind.zenFree.displayName,
            baseURL: "https://opencode.ai/zen/v1",
            requiresKey: false,
            riskNote: LLMBackendKind.zenFree.riskNote,
            extraHeaders: [
                "User-Agent": "opencode/1.18.30",
                "x-opencode-session": sessionID,
                "Authorization": "Bearer public",   // 公开哨兵值，非凭据（zen-proxy.mjs:495）
            ],
            staticModels: LLMModelCatalog.zenFree,
            chatCompletionsURLString: "https://opencode.ai/zen/v1/chat/completions",
            modelsURLString: "https://opencode.ai/zen/v1/models",
            modelPolicy: .zenFreeSuffixOnly,     // 实测付费模型 → 401
            visionRequiresKey: false,
            maxTokens: 4096
        )
    }
    func models(apiKey: String?) async throws -> [LLMModelInfo] {
        await fetchModels(descriptor: descriptor, apiKey: apiKey)
    }
    func makeRequest(model: String, messages: [LLMMessage], tools: [LLMToolSpec],
                     stream: Bool, apiKey: String) throws -> URLRequest {
        try buildRequest(descriptor: descriptor, model: model, messages: messages,
                         tools: tools, stream: stream, apiKey: apiKey)
    }
}

// ── ③ Pollinations（新 API）─────────────────────────────────────────────────

/// Pollinations gen API。**无任何特殊头**（规格 + 实测）。
/// 实测告警：chat/completions 当前返回 401 要 key（见文件头）→ riskNote 已如实追加。
struct PollinationsProvider: LLMBackendProvider {
    let descriptor = LLMBackendDescriptor(
        kind: .pollinations,
        displayName: LLMBackendKind.pollinations.displayName,
        baseURL: "https://gen.pollinations.ai/v1",
        requiresKey: false,
        riskNote: LLMBackendKind.pollinations.riskNote
            // 【措辞说明 · 2026-10-06】Lead 裁决：保持 requiresKey=false 不改契约
            //（其复测 4 次成功；)本机 9 次实测均为 401「A valid API key is required」，
            //  未见 429 → 门禁表现为**时段性波动**，双方观测不一致，故此处**不作确定性断言**，
            //  也不写成"限流"（未观测到 429，那样同样是编数据）。
            //  对用户的正确说法就是这句：可用性以探活为准。
            + "【可用性提示】该渠道免 key 门禁存在时段性波动"
            + "（同一时段实测可能返回 401 要求 API key，也可能正常应答）；"
            + "请以健康探活与降级链为准，勿假定它随时可用。",
        extraHeaders: [:],
        staticModels: LLMModelCatalog.pollinations,
        chatCompletionsURLString: "https://gen.pollinations.ai/v1/chat/completions",
        modelsURLString: "https://gen.pollinations.ai/v1/models",
        modelPolicy: .all,
        visionRequiresKey: true,                 // 规格：图片请求该渠道要 key → 视觉标志压平
        maxTokens: 4096
    )
    func models(apiKey: String?) async throws -> [LLMModelInfo] {
        await fetchModels(descriptor: descriptor, apiKey: apiKey)
    }
    func makeRequest(model: String, messages: [LLMMessage], tools: [LLMToolSpec],
                     stream: Bool, apiKey: String) throws -> URLRequest {
        try buildRequest(descriptor: descriptor, model: model, messages: messages,
                         tools: tools, stream: stream, apiKey: apiKey)
    }
}

// ── ④ Pollinations Legacy ──────────────────────────────────────────────────

/// Pollinations 旧 API（单模型兜底）。
/// **端点是实测出来的**：base 本身即 chat 端点，故 chat URL = {base}/chat/completions；
/// 而模型清单在 base 的上一级（https://text.pollinations.ai/models，实测 200 裸数组）。
struct PollinationsLegacyProvider: LLMBackendProvider {
    let descriptor = LLMBackendDescriptor(
        kind: .pollinationsLegacy,
        displayName: LLMBackendKind.pollinationsLegacy.displayName,
        baseURL: "https://text.pollinations.ai/openai",
        requiresKey: false,
        riskNote: LLMBackendKind.pollinationsLegacy.riskNote,
        extraHeaders: [:],
        staticModels: LLMModelCatalog.pollinationsLegacy,
        chatCompletionsURLString: "https://text.pollinations.ai/openai/chat/completions",
        modelsURLString: "https://text.pollinations.ai/models",
        modelPolicy: .all,
        visionRequiresKey: false,
        maxTokens: 4096
    )
    func models(apiKey: String?) async throws -> [LLMModelInfo] {
        await fetchModels(descriptor: descriptor, apiKey: apiKey)
    }
    func makeRequest(model: String, messages: [LLMMessage], tools: [LLMToolSpec],
                     stream: Bool, apiKey: String) throws -> URLRequest {
        try buildRequest(descriptor: descriptor, model: model, messages: messages,
                         tools: tools, stream: stream, apiKey: apiKey)
    }
}

// ── ⑤ 智谱 GLM（需 key）────────────────────────────────────────────────────

/// 智谱 GLM。实测无 key：/models 与 /chat/completions 均 401 code 1001。
struct ZhipuProvider: LLMBackendProvider {
    let descriptor = LLMBackendDescriptor(
        kind: .zhipu,
        displayName: LLMBackendKind.zhipu.displayName,
        baseURL: "https://open.bigmodel.cn/api/paas/v4",
        requiresKey: true,
        riskNote: LLMBackendKind.zhipu.riskNote,
        extraHeaders: [:],
        staticModels: LLMModelCatalog.zhipu,
        chatCompletionsURLString: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
        modelsURLString: "https://open.bigmodel.cn/api/paas/v4/models",
        modelPolicy: .all,
        visionRequiresKey: false,
        maxTokens: 4096
    )
    func models(apiKey: String?) async throws -> [LLMModelInfo] {
        await fetchModels(descriptor: descriptor, apiKey: apiKey)
    }
    func makeRequest(model: String, messages: [LLMMessage], tools: [LLMToolSpec],
                     stream: Bool, apiKey: String) throws -> URLRequest {
        try buildRequest(descriptor: descriptor, model: model, messages: messages,
                         tools: tools, stream: stream, apiKey: apiKey)
    }
}

// ── ⑥ Groq（需 key）────────────────────────────────────────────────────────

/// Groq（免费额度，低延迟）。实测无 key：GET /models → 403 Forbidden。
/// **静态表留空**：无 key 拿不到清单，也**不编造**模型名；一律走运行时 /models，
/// 拉取失败时该渠道无候选——如实反映，而不是拿假清单充数。
struct GroqProvider: LLMBackendProvider {
    let descriptor = LLMBackendDescriptor(
        kind: .groq,
        displayName: LLMBackendKind.groq.displayName,
        baseURL: "https://api.groq.com/openai/v1",
        requiresKey: true,
        riskNote: LLMBackendKind.groq.riskNote,
        extraHeaders: [:],
        staticModels: [],
        chatCompletionsURLString: "https://api.groq.com/openai/v1/chat/completions",
        modelsURLString: "https://api.groq.com/openai/v1/models",
        modelPolicy: .all,
        visionRequiresKey: false,
        maxTokens: 4096
    )
    func models(apiKey: String?) async throws -> [LLMModelInfo] {
        await fetchModels(descriptor: descriptor, apiKey: apiKey)
    }
    func makeRequest(model: String, messages: [LLMMessage], tools: [LLMToolSpec],
                     stream: Bool, apiKey: String) throws -> URLRequest {
        try buildRequest(descriptor: descriptor, model: model, messages: messages,
                         tools: tools, stream: stream, apiKey: apiKey)
    }
}

// ── ⑦ OpenRouter（需 key）──────────────────────────────────────────────────

/// OpenRouter。实测 GET /api/v1/models **公开可读**（200 / 464 条），
/// 但 chat 需 key。静态表留空（同 Groq 理由：不编模型名），走运行时清单。
struct OpenRouterProvider: LLMBackendProvider {
    let descriptor = LLMBackendDescriptor(
        kind: .openRouter,
        displayName: LLMBackendKind.openRouter.displayName,
        baseURL: "https://openrouter.ai/api/v1",
        requiresKey: true,
        riskNote: LLMBackendKind.openRouter.riskNote,
        extraHeaders: [:],
        staticModels: [],
        chatCompletionsURLString: "https://openrouter.ai/api/v1/chat/completions",
        modelsURLString: "https://openrouter.ai/api/v1/models",
        modelPolicy: .all,
        visionRequiresKey: false,
        maxTokens: 4096
    )
    func models(apiKey: String?) async throws -> [LLMModelInfo] {
        await fetchModels(descriptor: descriptor, apiKey: apiKey)
    }
    func makeRequest(model: String, messages: [LLMMessage], tools: [LLMToolSpec],
                     stream: Bool, apiKey: String) throws -> URLRequest {
        try buildRequest(descriptor: descriptor, model: model, messages: messages,
                         tools: tools, stream: stream, apiKey: apiKey)
    }
}

// ── ⑧ 用户自定义端点 ───────────────────────────────────────────────────────

/// 用户自定义的任意 OpenAI 兼容端点（复用 AgentSettings.baseUrl）。
///
/// 端点由用户在设置里填写 → 通过 `provider(for:apiKey:baseURLOverride:)` 现算。
struct UserKeyProvider: LLMBackendProvider {
    let baseURL: String

    init(baseURL: String) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    }

    var descriptor: LLMBackendDescriptor {
        LLMBackendDescriptor(
            kind: .userKey,
            displayName: LLMBackendKind.userKey.displayName,
            baseURL: baseURL,
            requiresKey: true,
            riskNote: LLMBackendKind.userKey.riskNote,
            extraHeaders: [:],
            staticModels: [],       // 自定义端点无法预知模型 → 一律运行时拉取
            chatCompletionsURLString: baseURL + "/chat/completions",
            modelsURLString: baseURL + "/models",
            modelPolicy: .all,
            visionRequiresKey: false,
            maxTokens: 4096
        )
    }
    func models(apiKey: String?) async throws -> [LLMModelInfo] {
        await fetchModels(descriptor: descriptor, apiKey: apiKey)
    }
    func makeRequest(model: String, messages: [LLMMessage], tools: [LLMToolSpec],
                     stream: Bool, apiKey: String) throws -> URLRequest {
        try buildRequest(descriptor: descriptor, model: model, messages: messages,
                         tools: tools, stream: stream, apiKey: apiKey)
    }
}

// MARK: - 注册表（对外唯一入口）

/// 渠道注册表：`LLMBackendKind` → `LLMBackendProvider`。
///
/// 【形状】Lead 冻结：`final class LLMBackendRegistry: @unchecked Sendable` +
/// `static let shared` + 4 个查询方法。W3/W7 已按此形状落盘调用。
///
/// 【为什么 provider 实例必须缓存】ZenFreeProvider 的 `x-opencode-session` 必须在
/// **同一实例内稳定复用**（规格：每个进程实例生成一次）；每次新建实例会换 session。
/// 故这里持有单例表 —— 全进程一处生成、处处复用。
final class LLMBackendRegistry: @unchecked Sendable {

    /// 全进程唯一实例
    static let shared = LLMBackendRegistry()

    /// 全渠道 provider 单例表（覆盖全部 8 个 case）。
    /// `userKey` 以 AgentSettings.baseUrl 的出厂默认值占位；
    /// 需要用户真实自定义端点时走 `provider(for:apiKey:baseURLOverride:)`。
    private let providers: [LLMBackendKind: any LLMBackendProvider]

    private init() {
        var table: [LLMBackendKind: any LLMBackendProvider] = [
            .ovhAnonymous: OVHAnonymousProvider(),
            .zenFree: ZenFreeProvider(),          // session 在此生成一次，全进程复用
            .pollinations: PollinationsProvider(),
            .pollinationsLegacy: PollinationsLegacyProvider(),
            .zhipu: ZhipuProvider(),
            .groq: GroqProvider(),
            .openRouter: OpenRouterProvider(),
            // AgentSettings.baseUrl 的出厂默认值（AgentSettings.swift:143）
            .userKey: UserKeyProvider(baseURL: AgentSettings().baseUrl),
        ]
        // 防御：确保 8 个 case 一个不少（漏一个会让 W3 探活静默少一条链）
        for kind in LLMBackendKind.allCases where table[kind] == nil {
            table[kind] = OVHAnonymousProvider()
        }
        self.providers = table
    }

    /// 取渠道 provider（**W3 探活入口**；W7 也可用）。
    /// - Parameters:
    ///   - kind: 渠道种类
    ///   - apiKey: 当前 API Key（`.userKey` 端点选择时可参考；其余渠道不影响静态描述）
    ///   - baseURLOverride: 仅 `.userKey` 有意义 —— 传 `settings.baseUrl`
    /// - Returns: 永远非 nil（8 个 case 全部有 provider）
    func provider(for kind: LLMBackendKind,
                  apiKey: String? = nil,
                  baseURLOverride: String? = nil) -> (any LLMBackendProvider)? {
        if kind == .userKey, let override = baseURLOverride, !override.isEmpty {
            let trimmed = override.hasSuffix("/") ? String(override.dropLast()) : override
            // 端点变更 → 现造实例（自定义端点的模型清单不可跨端点复用）
            if trimmed != (providers[.userKey]?.descriptor.baseURL ?? "") {
                return UserKeyProvider(baseURL: trimmed)
            }
        }
        return providers[kind]
    }

    /// 取渠道描述符（**W3 LLMHealth.swift:1313 / W7 AgentLoop.swift:510 调用的就是它**）。
    ///
    /// 契约：**对 4 个免 key 主力渠道（ovhAnonymous / zenFree / pollinations /
    /// pollinationsLegacy）绝不返回 nil**——W3 的探活链全靠它们。
    /// 实际实现对全部 8 个 case 都返回非 nil（本表由 init 补全）。
    func descriptor(for kind: LLMBackendKind) -> LLMBackendDescriptor? {
        providers[kind]?.descriptor
    }

    /// 取渠道描述符（`.userKey` 走用户自定义端点）
    func descriptor(for kind: LLMBackendKind, baseURLOverride: String?) -> LLMBackendDescriptor? {
        provider(for: kind, baseURLOverride: baseURLOverride)?.descriptor
    }

    /// 全部 8 个渠道的描述符（**按 LLMBackendKind.allCases 顺序**，即免 key 层在前）
    func allDescriptors() -> [LLMBackendDescriptor] {
        LLMBackendKind.allCases.compactMap { providers[$0]?.descriptor }
    }

    /// 全部渠道的静态模型清单（W6 模型菜单 / 自检用）
    /// - Parameter includeKeyed: false 时只返回免 key 渠道（未配置 key 的默认视图）
    func allModels(includeKeyed: Bool) -> [(LLMBackendKind, LLMModelInfo)] {
        allDescriptors()
            .filter { includeKeyed || !$0.requiresKey }
            .flatMap { descriptor in descriptor.staticModels.map { (descriptor.kind, $0) } }
    }

    /// 静态模型总数（诊断/自检用）
    var staticModelCount: Int {
        allDescriptors().reduce(0) { $0 + $1.staticModels.count }
    }
}
