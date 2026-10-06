// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  LLMTransport.swift — LLM 传输层（W2 · 2026-10-06）
// ============================================================================
//
//  【这一层负责什么 / 不负责什么】
//    负责：OpenAI 兼容协议的**发请求**与**收响应**。
//          · POST {base}/chat/completions（非流式 + SSE 流式）
//          · SSE 逐行解析（data: / [DONE] / delta.content / delta.reasoning_content
//            / delta.tool_calls 分片累积）
//          · 图片 part 编码（data URL；长边 1568px、JPEG 0.8 硬门限）
//          · 12 类错误分类（逐条对应实测上游返回）
//          · Task.cancel → .cancelled，不留悬挂连接
//    不负责：渠道描述符与模型表（W1 LLMBackend.swift）、健康/降级链（W3
//          LLMHealth.swift）、工具执行（W4 ToolRegistry.swift）、UI（W6）。
//
//  【为什么所有解析都写成纯函数】
//    W8 要离线自检：SSE 分片、错误分类、图片编码的判据必须能**不联网**复现。
//    因此 `SSEParser` / `LLMError.classify` / `LLMImageEncoder` 都是无状态
//    纯函数（不碰 URLSession、不读全局状态），可被 `--llm-selftest` 直接调用。
//
//  【性能红线（task-2 第 10 条）】
//    · 网络与解析全在 async 上下文（URLSession 自己的 delegate 队列），**绝不碰主线程**：
//      本文件没有一处 DispatchQueue.main、没有 @MainActor。
//    · URLSession 用**独立 configuration**（`LLMSessionPool`），与 captureQueue、
//      面板的 llmSession 完全分离：采集帧率不受 LLM 请求影响（ABBA 对照项）。
//    · 读取用 `URLSession.bytes(for:)` 逐字节流式消费，**按行 flush**（首字延迟最小），
//      不把整段 SSE 憋进内存再切。
//
//  【错误分类的出处：实测上游返回】
//    下面每一条 `case` 都对应一次真实抓到的响应体，逐条照抄、不自行增删分类：
//      {"type":"error","error":{"type":"FreeTierError"}}          → .gated
//      {"type":"error","error":{"type":"RegionError"}}            → .regionBlocked
//      ModelDeprecated + metadata.replacement                     → .modelDeprecated
//      ModelDeprecated 无 replacement（占位 no-replacement-available）→ .modelNotFound
//      server_error / HTTP 5xx                                    → .upstream
//      HTTP 429（Retry-After 头）                                 → .rateLimited
//      HTTP 401                                                   → .invalidKey
//      超时（URLError.timedOut）                                  → .timeout
//      连接失败（DNS/网络不可达）                                 → .network
//      HTTP 200 但 content 为空串（实测 space-bunny-free 会出现）  → .badResponse
//      Task.cancel                                                → .cancelled
//
//  【接口冻结】本文件的公开签名已与 W7 AgentLoop.swift（已落盘）逐字对齐：
//    LLMTransportFactory.make(baseURL:apiKey:extraHeaders:timeout:providerName:) -> (any LLMTransport)?
//    LLMRequest(baseURL:model:apiKey:messages:tools:stream:temperature:maxTokens:extraHeaders:providerName:timeout:)
//    LLMCompletion{text, toolCalls, usage, finishReason} / LLMToolCall{id, name, argumentsJSON}
//    LLMError{kind, message, retryAfter, replacementModel} / LLMErrorKind（12 类）
//    LLMMessage（W4 用 LLMToolSpec.make(name:description:parameters:)）
// ============================================================================

import Foundation
import ImageIO
import CoreGraphics
import os

// MARK: - 错误

/// 12 类 LLM 错误。拼写已冻结（W3 的 `noteFailure` 按 `LLMError.kind` 逐条分派状态）。
enum LLMErrorKind: String, Sendable, Codable, CaseIterable {
    /// 本地校验失败：需要 key 的渠道没给 key（**根本没发请求**）
    case missingKey
    /// 401：key 无效/过期（配置问题，**不是模型问题**）
    case invalidKey
    /// 429：限流（可能带 Retry-After）
    case rateLimited
    /// 免费档门禁（上游 FreeTierError）：容量池可能恢复，冷却后重试
    case gated
    /// 地区封锁（上游 RegionError）：换网络才会变，本会话内不必重探
    case regionBlocked
    /// 模型下线（上游 ModelDeprecated 且给了 replacement）
    case modelDeprecated
    /// 模型不存在/下线且无替代（ModelDeprecated 无 replacement、404）
    case modelNotFound
    /// 上游服务端错误（HTTP 5xx / server_error）
    case upstream
    /// 超时（URLError.timedOut；对流式是**空闲**超时语义）
    case timeout
    /// 网络层失败（DNS/不可达/连接中断）
    case network
    /// HTTP 成功但响应结构不可用（含实测的 200 + 空 content）
    case badResponse
    /// Task.cancel（用户取消）——**不是模型问题，不要记账、不要换候选**
    case cancelled
}

/// 传输层错误。W3 只做 `as? LLMError` 鸭子判定，因此额外字段（httpStatus/upstreamType）
/// 只作诊断，缺省即有值无。
struct LLMError: Error, Sendable, Equatable, LocalizedError {
    var kind: LLMErrorKind
    var message: String
    /// 429 时从 `Retry-After` 头（秒数或 HTTP-date）或上游 JSON 的 retry_after 解析
    var retryAfter: TimeInterval?
    /// ModelDeprecated 时的 `metadata.replacement`（W3 用它切模型）
    var replacementModel: String?
    /// 附加诊断：HTTP 状态码
    var httpStatus: Int?
    /// 附加诊断：上游原始 `error.type`
    var upstreamType: String?

    init(kind: LLMErrorKind, message: String, retryAfter: TimeInterval? = nil,
         replacementModel: String? = nil, httpStatus: Int? = nil, upstreamType: String? = nil) {
        self.kind = kind
        self.message = message
        self.retryAfter = retryAfter
        self.replacementModel = replacementModel
        self.httpStatus = httpStatus
        self.upstreamType = upstreamType
    }

    var errorDescription: String? { "\(kind.rawValue)：\(message)" }
}

// MARK: - 错误分类（纯函数 · W8 可离线自检）

extension LLMError {

    /// 上游 `metadata.replacement` 的占位值：**出现它等于没有替代模型**。
    /// 实测：ModelDeprecated 的 metadata 形如 `{"replacement":"no-replacement-available"}`，
    /// 此时按 task-2 第 8 条必须归到 .modelNotFound，而不是 .modelDeprecated。
    static let replacementPlaceholder = "no-replacement-available"

    static func missingKeyError(_ message: String) -> LLMError {
        LLMError(kind: .missingKey, message: message)
    }

    static func cancelledError(_ message: String = "已取消") -> LLMError {
        LLMError(kind: .cancelled, message: message)
    }

    /// 把 HTTP 状态 + 响应体分类成 12 类之一。**纯函数**：只依赖入参，不碰网络/全局。
    ///
    /// 判定优先级（先看上游给的语义类型，再看 HTTP 码，最后看散文）：
    ///   FreeTierError > RegionError > ModelDeprecated > 401/403 > 429 > 5xx/server_error
    ///   > 404 > 其它 4xx > 兜底 .upstream
    static func classify(status: Int,
                         body: Data,
                         retryAfterHeader: String? = nil,
                         effectiveURL: String? = nil) -> LLMError {
        let rawText = String(data: body, encoding: .utf8) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let rootType = (json?["type"] as? String) ?? ""
        let errorObject = json?["error"] as? [String: Any]
        let nestedType = (errorObject?["type"] as? String) ?? ""
        let nestedMessage = (errorObject?["message"] as? String) ?? ""
        let topMessage = (json?["message"] as? String) ?? ""

        func mentions(_ needle: String) -> Bool {
            rootType == needle || nestedType == needle || rawText.contains(needle)
        }
        func statusText(_ fallback: String) -> String {
            let parts = [nestedMessage, topMessage].filter { !$0.isEmpty }
            if let first = parts.first { return first }
            if !fallback.isEmpty { return fallback }
            return rawText.isEmpty ? "(空响应体)" : String(rawText.prefix(200))
        }

        // ① 上游语义类型优先（实测响应体里 error.type 是权威信号）
        if mentions("FreeTierError") {
            return LLMError(kind: .gated,
                            message: statusText("免费档门禁（FreeTierError）"),
                            httpStatus: status, upstreamType: "FreeTierError")
        }
        if mentions("RegionError") {
            return LLMError(kind: .regionBlocked,
                            message: statusText("地区封锁（RegionError）"),
                            httpStatus: status, upstreamType: "RegionError")
        }
        if mentions("ModelDeprecated") {
            let replacement = Self.replacementModel(in: json) ?? Self.replacementModel(in: errorObject)
            if let replacement, !replacement.isEmpty, replacement != Self.replacementPlaceholder {
                return LLMError(kind: .modelDeprecated,
                                message: statusText("模型已下线，替代：\(replacement)"),
                                replacementModel: replacement,
                                httpStatus: status, upstreamType: "ModelDeprecated")
            }
            return LLMError(kind: .modelNotFound,
                            message: statusText("模型已下线且无替代（ModelDeprecated）"),
                            httpStatus: status, upstreamType: "ModelDeprecated")
        }

        // ② HTTP 状态码
        if status == 401 || status == 403 {
            return LLMError(kind: .invalidKey,
                            message: statusText("API Key 无效或无权限（HTTP \(status)）"),
                            httpStatus: status, upstreamType: nestedType.isEmpty ? nil : nestedType)
        }
        if status == 429 {
            let retryAfter = Self.retryAfterSeconds(header: retryAfterHeader) ?? Self.retryAfterSeconds(in: json)
            return LLMError(kind: .rateLimited,
                            message: statusText("限流（HTTP 429）"),
                            retryAfter: retryAfter,
                            httpStatus: status, upstreamType: nestedType.isEmpty ? nil : nestedType)
        }
        if status >= 500 || mentions("server_error") {
            return LLMError(kind: .upstream,
                            message: statusText("上游服务端错误（HTTP \(status)）"),
                            httpStatus: status,
                            upstreamType: nestedType.isEmpty ? (mentions("server_error") ? "server_error" : nil) : nestedType)
        }
        if status == 404 {
            return LLMError(kind: .modelNotFound,
                            message: statusText("模型或端点不存在（HTTP 404）"),
                            httpStatus: status, upstreamType: nestedType.isEmpty ? nil : nestedType)
        }
        if status >= 400 {
            // 其它 4xx：上游拒绝了这次请求（参数/内容策略等），如实归为 upstream
            return LLMError(kind: .upstream,
                            message: statusText("上游拒绝请求（HTTP \(status)）"),
                            httpStatus: status, upstreamType: nestedType.isEmpty ? nil : nestedType)
        }

        // ③ 兜底：HTTP 成功但走到这里说明调用方拿到了不该走分类的响应
        return LLMError(kind: .upstream,
                        message: statusText("未分类的上游错误（HTTP \(status)）"),
                        httpStatus: status, upstreamType: nestedType.isEmpty ? nil : nestedType)
    }

    /// 取 `metadata.replacement`（也兼容 `metadata.model_replacement`）
    static func replacementModel(in object: [String: Any]?) -> String? {
        guard let metadata = object?["metadata"] as? [String: Any] else { return nil }
        if let replacement = metadata["replacement"] as? String { return replacement }
        if let replacement = metadata["model_replacement"] as? String { return replacement }
        return nil
    }

    /// `Retry-After` 头：RFC 7231 允许「秒数」或「HTTP-date」两种形式，都要认。
    static func retryAfterSeconds(header: String?) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return seconds > 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            let delta = date.timeIntervalSinceNow
            return delta > 0 ? delta : nil
        }
        return nil
    }

    /// 上游 JSON 里的 retry 提示（有些渠道不给 Retry-After 头，只在 body 给 retry_after/retryDelay）
    static func retryAfterSeconds(in json: [String: Any]?) -> TimeInterval? {
        let containers: [[String: Any]?] = [json, json?["error"] as? [String: Any]]
        for container in containers {
            guard let container else { continue }
            for key in ["retry_after", "retryAfter", "retry_after_seconds"] {
                if let value = container[key] as? Int { return value > 0 ? TimeInterval(value) : nil }
                if let value = container[key] as? Double { return value > 0 ? value : nil }
                if let text = container[key] as? String, let value = TimeInterval(text), value > 0 { return value }
            }
        }
        return nil
    }

    /// URLError / 其它 Swift 错误 → LLMError（`.cancelled` 只认 Task.cancel，不误报）
    static func map(_ error: Error, context: String = "") -> LLMError {
        if let llmError = error as? LLMError { return llmError }
        if error is CancellationError { return LLMError.cancelledError() }
        guard let urlError = error as? URLError else {
            return LLMError(kind: .network, message: context.isEmpty ? "\(error)" : "\(context)：\(error)")
        }
        let suffix = context.isEmpty ? "" : "（\(context)）"
        switch urlError.code {
        case .timedOut:
            return LLMError(kind: .timeout, message: "请求超时\(suffix)")
        case .cancelled:
            // URLSession 的 .cancelled 也可能来自主动 invalidate；只有 Task 真被取消才报 .cancelled
            if Task.isCancelled { return LLMError.cancelledError() }
            return LLMError(kind: .network, message: "连接被取消\(suffix)")
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
             .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .dataNotAllowed, .internationalRoamingOff, .callIsActive,
             .appTransportSecurityRequiresSecureConnection, .badServerResponse:
            return LLMError(kind: .network, message: "网络不可用\(suffix)：\(urlError.localizedDescription)")
        default:
            return LLMError(kind: .network, message: "网络错误\(suffix)：\(urlError.localizedDescription)")
        }
    }
}

// MARK: - 消息与工具

/// 消息角色。**enum 而非 String**（编译期防拼错）；需要字符串时用 `rawValue`。
enum LLMRole: String, Sendable, Codable, CaseIterable {
    case system, user, assistant, tool
}

/// 待发送的图片。`data` 是**已经压缩好**的字节（见 `LLMImageEncoder`：长边 1568px、JPEG 0.8）。
struct LLMImage: Sendable, Equatable {
    var data: Data
    var mimeType: String
    var pixelWidth: Int?
    var pixelHeight: Int?

    init(data: Data, mimeType: String = "image/jpeg", pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// base64 文本（data URL 的内层）
    var base64: String { data.base64EncodedString() }
    /// OpenAI 兼容的 data URL
    var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
    /// data URL 的**估算**字节量（实测判据：762KB base64 可用；原图 2940×1912 约 8MB 会超限）
    var encodedByteCount: Int { data.count * 4 / 3 + 24 }
}

/// 一条对话消息。
///
/// 【为什么 role 收 String 而内部有 enum】冻结契约规定 `role: String`（W7 用
/// `.system(_:)` / `.user(_:)` 工厂，不手写 role），两种构造器都提供。
struct LLMMessage: Sendable, Equatable {
    /// "system" / "user" / "assistant" / "tool"（冻结契约：字符串）
    var role: String
    var text: String?
    var images: [LLMImage]?
    var toolCallID: String?

    init(role: String, text: String? = nil, images: [LLMImage]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.text = text
        self.images = images
        self.toolCallID = toolCallID
    }

    init(role: LLMRole, text: String? = nil, images: [LLMImage]? = nil, toolCallID: String? = nil) {
        self.init(role: role.rawValue, text: text, images: images, toolCallID: toolCallID)
    }

    static func system(_ text: String) -> LLMMessage { LLMMessage(role: .system, text: text) }
    static func user(_ text: String, images: [LLMImage]? = nil) -> LLMMessage {
        LLMMessage(role: .user, text: text, images: images)
    }
    static func assistant(_ text: String) -> LLMMessage { LLMMessage(role: .assistant, text: text) }
    static func tool(_ text: String, toolCallID: String) -> LLMMessage {
        LLMMessage(role: .tool, text: text, toolCallID: toolCallID)
    }

    /// OpenAI 兼容的 message 字典。
    ///
    /// 关键细节（踩过的坑）：
    ///  · **无图**时 `content` 必须是字符串，且**即使是空串也要写这个键**——
    ///    工具调用回合 assistant 不再带文本，缺 `content` 键会让部分渠道 400。
    ///  · **有图**时 content 变数组：`{"type":"text"}` + `{"type":"image_url"}`（task-2 第 7 条）。
    func openAIDictionary() -> [String: Any] {
        var dict: [String: Any] = ["role": role]
        let body = text ?? ""
        let pictures = images ?? []
        if pictures.isEmpty {
            dict["content"] = body
        } else {
            var parts: [[String: Any]] = []
            if !body.isEmpty { parts.append(["type": "text", "text": body]) }
            for picture in pictures {
                parts.append(["type": "image_url", "image_url": ["url": picture.dataURL]])
            }
            dict["content"] = parts
        }
        if let toolCallID, !toolCallID.isEmpty { dict["tool_call_id"] = toolCallID }
        return dict
    }

    var hasImages: Bool { !(images ?? []).isEmpty }
}

/// function-calling 工具规格。`parametersJSON` 是**已序列化**的 JSON Schema 对象
/// （W4 通过 `make(name:description:parameters:)` 产出），传输层只负责塞进 `parameters`。
struct LLMToolSpec: Sendable, Equatable {
    var name: String
    var description: String
    var parametersJSON: String

    init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }

    /// 从 JSON Schema 字典构造（W4 `ToolRegistry.specs()` 用）。
    /// 序列化失败即抛错——**不静默丢工具**。
    static func make(name: String, description: String, parameters: [String: Any] = [:]) throws -> LLMToolSpec {
        let object: [String: Any] = parameters.isEmpty
            ? ["type": "object", "properties": [String: Any]()]
            : parameters
        guard JSONSerialization.isValidJSONObject(object) else {
            throw LLMError(kind: .badResponse, message: "工具 \(name) 的 schema 不是合法 JSON 对象")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LLMError(kind: .badResponse, message: "工具 \(name) 的 schema 无法转成 UTF-8")
        }
        return LLMToolSpec(name: name, description: description, parametersJSON: json)
    }

    /// `{"type":"function","function":{name,description,parameters}}`（task-2：包装层只在这里出现）
    func openAIDictionary() -> [String: Any] {
        var function: [String: Any] = ["name": name]
        if !description.isEmpty { function["description"] = description }
        if let data = parametersJSON.data(using: .utf8),
           let parameters = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            function["parameters"] = parameters
        } else {
            function["parameters"] = ["type": "object", "properties": [String: Any]()]
        }
        return ["type": "function", "function": function]
    }
}

// MARK: - 流式事件与结果

/// 流式事件。
///
/// 【toolCall 的 id 语义】SSE 分片里 `id` 与 `function.name` 只在**首个**片段出现，
/// 后续片段只有 `function.arguments`。因此约定：`id` 为空串 = 「上一个工具调用的续片」，
/// 累加器会把 arguments 拼到上一项（W7 只取第一个调用，足够用）。
enum LLMStreamEvent: Sendable {
    case delta(String)
    case reasoning(String)
    case toolCall(id: String, name: String, argumentsJSON: String)
    case done(LLMCompletion)
}

struct LLMToolCall: Sendable, Equatable {
    var id: String
    var name: String
    /// 原始 JSON 字符串（未解析）；调用方按需 JSONSerialization
    var argumentsJSON: String
}

struct LLMUsage: Sendable, Equatable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?

    init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }

    var isEmpty: Bool { promptTokens == nil && completionTokens == nil && totalTokens == nil }
}

struct LLMCompletion: Sendable, Equatable {
    /// 正文。有 toolCalls 时可能为合法空串（**空 content + 有 toolCalls 不算失败**）
    var text: String
    var toolCalls: [LLMToolCall]
    var usage: LLMUsage?
    var finishReason: String?
    /// 实际使用的模型（上游回显）
    var model: String?
    /// 推理内容（部分渠道给 reasoning_content）
    var reasoning: String?

    init(text: String = "", toolCalls: [LLMToolCall] = [], usage: LLMUsage? = nil,
         finishReason: String? = nil, model: String? = nil, reasoning: String? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.usage = usage
        self.finishReason = finishReason
        self.model = model
        self.reasoning = reasoning
    }

    static let empty = LLMCompletion()
}

// MARK: - 请求

/// 一次完整的请求描述。**自包含**（baseURL/apiKey 都在里面），因此传输实现可以无状态。
struct LLMRequest: Sendable {
    var baseURL: String
    var model: String
    /// nil 或空串 = 不带 Authorization（免 key 渠道：OVH/Pollinations）；
    /// Zen 的 `Bearer public` 由 W1 描述符放进 extraHeaders。
    var apiKey: String?
    var messages: [LLMMessage]
    var tools: [LLMToolSpec]?
    var stream: Bool
    var temperature: Double
    var maxTokens: Int?
    var extraHeaders: [String: String]
    var providerName: String
    /// **空闲**超时语义（URLSession.timeoutIntervalForRequest：两个数据包之间的最大间隔），
    /// 而不是整段生成的总时长——流式长回答不会被它腰斩。
    var timeout: TimeInterval
    /// 视觉请求标记：true 时若 messages 里一张图都没有，直接抛 .badResponse。
    /// 【为什么强制】用户规格要求「无视觉候选时如实提示，不静默降级」——
    /// 静默降级会让用户以为模型看了屏幕，实际没看（等于骗人）。
    var vision: Bool
    /// 该渠道是否需要 API Key（默认 false，由渠道描述符决定）。true 而 apiKey 为空 →
    /// 立刻抛 .missingKey（**不发请求**，不浪费共享配额）。
    var requiresKey: Bool

    init(baseURL: String, model: String, apiKey: String?, messages: [LLMMessage],
         tools: [LLMToolSpec]?, stream: Bool, temperature: Double, maxTokens: Int?,
         extraHeaders: [String: String], providerName: String, timeout: TimeInterval,
         vision: Bool = false, requiresKey: Bool = false) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.messages = messages
        self.tools = tools
        self.stream = stream
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.extraHeaders = extraHeaders
        self.providerName = providerName
        self.timeout = timeout
        self.vision = vision
        self.requiresKey = requiresKey
    }
}

// MARK: - 传输协议

/// 传输协议。`complete` = 一次拿完（内部自动聚合）；`stream` = 边收边给。
/// 两者语义等价（同一份解析代码），调用方按 UI 需要选。
protocol LLMTransport: Sendable {
    func complete(_ req: LLMRequest) async throws -> LLMCompletion
    func stream(_ req: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

// MARK: - SSE 纯解析（离线可自检）

/// SSE 增量解析状态。字段全 `var`，可由 W8 直接摆布做离线断言。
struct SSEStreamState: Sendable {
    var buffer = Data()
    var pendingEvent: String?
    var pendingData = ""
    var sawDoneSentinel = false
    /// 兼容模式：整个响应不是合法 SSE（某些免 key 端点对 stream=true 直接回普通 JSON）
    var sawSSEField = false

    init() {}
}

/// 单个 SSE data 片段的解析结果（纯值类型，方便 W8 离线断言）
struct LLMChunkParse: Sendable {
    var events: [LLMStreamEvent] = []
    var finishReason: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var model: String?
    /// 上游把错误对象当正常响应回（HTTP 200 + {"error":...}）时在这里如实带出
    var error: LLMError?

    init() {}

    var isEmpty: Bool {
        events.isEmpty && finishReason == nil && promptTokens == nil
            && completionTokens == nil && totalTokens == nil && model == nil && error == nil
    }

    mutating func apply(usage: [String: Any]) {
        promptTokens = usage["prompt_tokens"] as? Int ?? promptTokens
        completionTokens = usage["completion_tokens"] as? Int ?? completionTokens
        totalTokens = usage["total_tokens"] as? Int ?? totalTokens
    }
}

/// SSE 纯函数解析器：`Data → [LLMChunkParse]`。
///
/// 【为什么按字节切行而不是 String】
///   `String(data:encoding:.utf8)` 遇到被切断的多字节字符会整段返回 nil —— 中文
///   内容正好会被切在包边界上（实测部分渠道），按字节找 `\n` 再逐行解码才不丢字。
///
/// 【容错】上游可能：
///   · 用 `\r\n` 或 `\n` 分行（两种都认）
///   · 不写空行分隔事件（直接一行一个 data:）
///   · 给 `: keep-alive` 注释行（忽略）
///   · 给非 SSE 的裸 JSON（按 JSON 片段处理）
///   这些情况都不抛错，能解析多少算多少。
enum SSEParser {

    /// 单个事件缓冲上限：8MB。超过即视为上游异常（避免畸形流把内存吃爆）
    static let maxEventBytes = 8 << 20

    /// 解一行字节 → 文本（容错：截断的多字节序列不整行丢弃）
    static func decodeLine(_ data: Data) -> String {
        if data.isEmpty { return "" }
        if let text = String(data: data, encoding: .utf8) { return text }
        let dropLimit = min(3, data.count)
        if dropLimit >= 1 {
            for drop in 1...dropLimit {
                if let text = String(data: data.dropLast(drop), encoding: .utf8) { return text }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 取 SSE 行首字段名：`data: {...}` → `data`，`: keep-alive` → 空串
    static func fieldName(_ line: String) -> String {
        var name = ""
        for character in line {
            if character == ":" { return name }
            if character.isWhitespace { return "" }   // 无冒号的行：整行是字段名，空格即结束
            name.append(character)
        }
        return name
    }

    static func fieldValue(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        return value
    }

    // MARK: 增量入口

    /// 喂进一个网络分片，产出本次能确定的解析结果。**不联网、无副作用。**
    static func consume(_ state: inout SSEStreamState, chunk: Data) -> [LLMChunkParse] {
        state.buffer.append(chunk)
        var parses: [LLMChunkParse] = []

        while let newline = state.buffer.firstIndex(of: 0x0A) {
            let lineData = Data(state.buffer[state.buffer.startIndex..<newline])
            state.buffer.removeSubrange(state.buffer.startIndex...newline)
            parses.append(contentsOf: handleLine(&state, lineData: lineData))
        }

        // 安全阀：一整行都凑不出来还堆了 8MB+ → 上游在灌垃圾
        if state.buffer.count > maxEventBytes {
            reset(&state)
        }
        return parses
    }

    /// 流结束时的兜底：缓冲里可能还剩「不带换行的裸 JSON」或半行。
    static func finish(_ state: inout SSEStreamState) -> [LLMChunkParse] {
        var parses: [LLMChunkParse] = []
        if !state.buffer.isEmpty {
            let residue = state.buffer
            state.buffer.removeAll(keepingCapacity: false)
            parses.append(contentsOf: handleLine(&state, lineData: residue))
        }
        // 事件分隔：把最后一段没等到空行的 data 冲出去
        parses.append(contentsOf: drainObjects(&state))
        // 兼容模式：全程没见到 SSE 字段 → 把整段残余当一个 JSON 响应体解析
        if parses.isEmpty, !state.sawSSEField {
            let residue = state.pendingData.trimmingCharacters(in: .whitespacesAndNewlines)
            if !residue.isEmpty, let parse = parse(json: residue) {
                state.pendingData = ""
                parses.append(parse)
            }
        }
        reset(&state)
        return parses
    }

    static func reset(_ state: inout SSEStreamState) {
        state.buffer.removeAll(keepingCapacity: false)
        state.pendingData = ""
        state.pendingEvent = nil
    }

    /// 处理一行（已经按字节切好）。返回 0 个或多个解析结果
    /// （一行里理论上可以塞多个 JSON 对象；虽罕见，但不丢）。
    static func handleLine(_ state: inout SSEStreamState, lineData: Data) -> [LLMChunkParse] {
        let rawLine = decodeLine(lineData)
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

        if line.isEmpty {
            // 空行 = 事件分隔符
            return drainObjects(&state)
        }
        if line.hasPrefix(":") { return [] }       // 注释/心跳

        let name = fieldName(line)
        let value = fieldValue(line)

        switch name {
        case "data":
            state.sawSSEField = true
            state.pendingEvent = state.pendingEvent ?? "message"
            if value.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                state.sawDoneSentinel = true
                var parses = drainObjects(&state)
                // [DONE] 之后残余的 data 不再有意义
                state.pendingData = ""
                state.pendingEvent = nil
                if parses.isEmpty { parses = [] }
                return parses
            }
            if !state.pendingData.isEmpty { state.pendingData.append("\n") }
            state.pendingData += value
            // 【关键】不能只等空行：实测有渠道**不写空行**，直接一行一个 data: {...}。
            // 因此 data 值已经是完整 JSON 对象时就立刻出结果（括号配对扫描，不误切）。
            return drainObjects(&state)

        case "event":
            state.sawSSEField = true
            state.pendingEvent = value
            return []

        case "id", "retry":
            state.sawSSEField = true
            return []

        default:
            // 非 SSE 字段行：可能是裸 JSON 流的一部分。
            // 若已见过 SSE 字段，说明这是上游塞的杂质 → 忽略；否则按 JSON 兜底处理。
            if state.sawSSEField { return [] }
            if state.pendingData.isEmpty { state.pendingData = line } else { state.pendingData += "\n" + line }
            return drainObjects(&state)
        }
    }

    /// 把 pendingData 里所有**已完整**的 JSON 对象切出来解析，剩余留给后续分片。
    static func drainObjects(_ state: inout SSEStreamState) -> [LLMChunkParse] {
        var parses: [LLMChunkParse] = []
        while let (object, consumed) = extractJSONObject(state.pendingData) {
            state.pendingData = String(state.pendingData.dropFirst(consumed))
            if let parse = parse(json: object) { parses.append(parse) }
        }
        // 全是空白 → 清掉，避免无限累积
        if state.pendingData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.pendingData = ""
        }
        return parses
    }

    // MARK: 片段 → 结果

    /// 一个 JSON 片段 → 解析结果（**纯函数**）
    static func parse(json: String) -> LLMChunkParse? {
        guard let data = json.data(using: .utf8) else { return nil }
        let parse = parse(chunk: data)
        return parse.isEmpty ? nil : parse
    }

    /// 一个 SSE data 片段 → 解析结果（**纯函数**，W8 主自检入口）
    static func parse(chunk: Data) -> LLMChunkParse {
        var result = LLMChunkParse()
        guard let root = (try? JSONSerialization.jsonObject(with: chunk)) as? [String: Any] else { return result }

        // 上游也可能直接回 error 对象（HTTP 200 + 错误体）
        if root["error"] is [String: Any] {
            result.error = LLMError.classify(status: 200, body: chunk)
            return result
        }

        guard let choices = root["choices"] as? [[String: Any]], let first = choices.first else {
            if let usage = root["usage"] as? [String: Any] { result.apply(usage: usage) }
            if let model = root["model"] as? String { result.model = model }
            return result
        }

        // 流式形状 delta / 非流式形状 message（免 key 端点可能无视 stream=true 直接回整包）
        let delta = (first["delta"] as? [String: Any]) ?? (first["message"] as? [String: Any]) ?? [:]

        if let text = delta["content"] as? String, !text.isEmpty { result.events.append(.delta(text)) }
        if let legacy = first["text"] as? String, !legacy.isEmpty, delta["content"] == nil {
            result.events.append(.delta(legacy))
        }
        for key in ["reasoning_content", "reasoning"] {
            if let reasoning = delta[key] as? String, !reasoning.isEmpty {
                result.events.append(.reasoning(reasoning))
                break
            }
        }
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            result.events.append(contentsOf: toolCallEvents(calls))
        }
        if let finish = first["finish_reason"] as? String, !finish.isEmpty {
            result.finishReason = finish
        }
        if let usage = root["usage"] as? [String: Any] { result.apply(usage: usage) }
        if let model = root["model"] as? String { result.model = model }
        return result
    }

    /// tool_calls 分片 → 事件（id 只在首片出现；arguments 可能被切成任意多片）
    static func toolCallEvents(_ calls: [[String: Any]]) -> [LLMStreamEvent] {
        calls.compactMap { call in
            let id = call["id"] as? String ?? ""
            let function = call["function"] as? [String: Any] ?? [:]
            let name = function["name"] as? String ?? ""
            var arguments = ""
            if let text = function["arguments"] as? String {
                arguments = text
            } else if let object = function["arguments"], JSONSerialization.isValidJSONObject(object),
                      let data = try? JSONSerialization.data(withJSONObject: object),
                      let text = String(data: data, encoding: .utf8) {
                arguments = text
            }
            if id.isEmpty && name.isEmpty && arguments.isEmpty { return nil }
            return .toolCall(id: id, name: name, argumentsJSON: arguments)
        }
    }

    // MARK: JSON 对象边界扫描（纯函数）

    /// 从字符串里切出一个完整的顶层 JSON 对象，返回 (对象文本, 消耗的**字符**数)。
    ///
    /// 用字符串/转义状态机而非 `index(of: "{")`：模型返回的代码/文本里含 `{`、`}`
    /// 不会被误判为对象边界（这是自己写 SSE 解析最常见的翻车点）。
    static func extractJSONObject(_ text: String) -> (String, Int)? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                if character == "\"" {
                    inString = true
                } else if character == "{" {
                    if depth == 0 { start = index }
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0, let begin = start {
                        let end = text.index(after: index)
                        let object = String(text[begin..<end])
                        return (object, text.distance(from: text.startIndex, to: end))
                    }
                    if depth < 0 { depth = 0; start = nil }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

/// 流式累加器：把分片解析结果拼成完整结果（SSE 分片 → LLMCompletion）。
struct LLMStreamAccumulator: Sendable {
    private(set) var text = ""
    private(set) var reasoning = ""
    private(set) var toolCalls: [LLMToolCall] = []
    private(set) var finishReason: String?
    private(set) var usage: LLMUsage?
    private(set) var model: String?
    private(set) var chunkCount = 0
    /// 是否收到过**有效**分片（区分「空 content」与「压根没响应」）
    private(set) var sawContentChunk = false

    init() {}

    mutating func noteChunk(_ parse: LLMChunkParse) {
        chunkCount += 1
        if let finish = parse.finishReason { finishReason = finish }
        if let model = parse.model { self.model = model }
        var tokens = usage ?? LLMUsage()
        if let value = parse.promptTokens { tokens.promptTokens = value }
        if let value = parse.completionTokens { tokens.completionTokens = value }
        if let value = parse.totalTokens { tokens.totalTokens = value }
        if !tokens.isEmpty { usage = tokens }
        for event in parse.events { apply(event) }
    }

    mutating func apply(_ event: LLMStreamEvent) {
        switch event {
        case .delta(let piece):
            text += piece
            sawContentChunk = true
        case .reasoning(let piece):
            reasoning += piece
        case .toolCall(let id, let name, let arguments):
            sawContentChunk = true
            appendToolCall(id: id, name: name, arguments: arguments)
        case .done(let completion):
            if !completion.text.isEmpty { text += completion.text }
            if !completion.toolCalls.isEmpty { toolCalls.append(contentsOf: completion.toolCalls) }
            if let finish = completion.finishReason { finishReason = finish }
            if let value = completion.usage { usage = value }
            if let value = completion.model { model = value }
        }
    }

    /// 分片拼接规则：id 空 = 续片（拼到上一项）；id 命中已有项 = 继续拼；否则新开一项。
    mutating func appendToolCall(id: String, name: String, arguments: String) {
        if !id.isEmpty, let index = toolCalls.firstIndex(where: { $0.id == id }) {
            if !name.isEmpty { toolCalls[index].name += name }
            toolCalls[index].argumentsJSON += arguments
            return
        }
        if id.isEmpty, !toolCalls.isEmpty {
            let last = toolCalls.count - 1
            if !name.isEmpty { toolCalls[last].name += name }
            toolCalls[last].argumentsJSON += arguments
            return
        }
        toolCalls.append(LLMToolCall(id: id.isEmpty ? "call_\(toolCalls.count)" : id,
                                     name: name, argumentsJSON: arguments))
    }

    var completion: LLMCompletion {
        LLMCompletion(text: text, toolCalls: toolCalls, usage: usage,
                      finishReason: finishReason, model: model,
                      reasoning: reasoning.isEmpty ? nil : reasoning)
    }
}

// MARK: - 图片编码（纯函数 · 离线可自检）

/// 图片编码器：任何输入（CGImage / PNG / JPEG / base64 / data URL / HTML 错误页 / http URL）
/// 都收敛成**符合硬门限**的 `LLMImage`（长边 ≤1568px、JPEG 0.8）。
///
/// 【硬门限的实测依据（task-2 第 7 条）】
///   · 762KB base64 的截图实测可用；
///   · 2940×1912 原图（未压缩）约 8MB，发给上游会超限被拒。
///   所以发送前一律缩放 + JPEG 0.8，并再设一道 2MB 兜底（压缩后仍超 → 明确报错，不硬发）。
///
/// 【线程约定】本枚举全部是**纯 CPU 函数**（除了 `prepare(urlString:)` 会同步下载）。
/// 调用方必须在后台上下文调用（`prepare(urlString:)` 尤其**禁止在主线程**）。
enum LLMImageEncoder {

    /// 长边上限（px）
    static let maxLongEdge = 1568
    /// JPEG 质量
    static let jpegQuality = 0.8
    /// 压缩后字节上限（约 1MB base64 的 4/3 倍余量）
    static let maxEncodedBytes = 2_000_000

    /// 图片下载专用 session（独立于 LLM 会话；15s 空闲超时）
    static let imageSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    // MARK: 入口

    /// 把任意来源的 base64 变成合规图片（base64 / data URL / 上游把 HTML 错误页当图片发的坑都兜住）。
    static func prepare(base64: String, mimeType: String? = nil) throws -> LLMImage {
        let cleaned = stripDataURLPrefix(base64)
        guard let data = Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters]) else {
            throw LLMError(kind: .badResponse, message: "base64 图片无法解码（\(cleaned.count) 字符）")
        }
        return try prepare(data: data, mimeType: mimeType)
    }

    /// 本地字节（PNG/JPEG/…）→ 合规图片
    static func prepare(data: Data, mimeType: String? = nil) throws -> LLMImage {
        if let image = try? encode(data: data) { return image }
        let declared = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines)
        // ① 声明本身就是地址（有些渠道把图片地址塞在 mime_type 字段）
        if let declared, declared.hasPrefix("http"), let url = URL(string: declared) {
            return try prepare(urlString: url.absoluteString)
        }
        // ② 内容是 HTML 页面 → 抠 og:image 再取一次
        if isHTML(data),
           let text = String(data: data.prefix(8192), encoding: .utf8),
           let url = extractImageURL(from: text) {
            return try prepare(urlString: url)
        }
        try throwNonImage(data, mimeType: declared)
    }

    /// http(s) 地址 → 合规图片（15s 超时；失败如实抛出）。
    /// - Warning: **同步阻塞**（最长 20s），禁止在主线程调用。
    static func prepare(urlString: String) throws -> LLMImage {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw LLMError(kind: .badResponse, message: "图片地址无效：\(trimmed.prefix(80))")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ImageFetchBox()
        let task = imageSession.dataTask(with: url) { data, response, error in
            box.store(data: data, response: response as? HTTPURLResponse, error: error)
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            task.cancel()
            throw LLMError(kind: .timeout, message: "图片下载超时（20s）：\(url.host ?? trimmed)")
        }
        if let error = box.error { throw LLMError.map(error, context: "图片下载") }
        guard let data = box.data else {
            throw LLMError(kind: .network, message: "图片下载无数据：\(trimmed.prefix(80))")
        }
        if let status = box.status, !(200...299).contains(status) {
            throw LLMError(kind: .network, message: "图片下载失败：HTTP \(status)")
        }
        if let image = try? encode(data: data) { return image }
        try throwNonImage(data, mimeType: box.mimeType)
    }

    /// 已经是 JPEG 的字节 → 合规图片（不再二次转码；超限则走完整编码）
    static func encode(jpegData: Data) throws -> LLMImage {
        try encode(data: jpegData)
    }

    /// 任意图片字节（PNG/JPEG/HEIC/…）→ 合规 JPEG 图片
    static func encode(data: Data) throws -> LLMImage {
        guard !data.isEmpty else { throw LLMError(kind: .badResponse, message: "图片数据为空") }
        // 已经是 JPEG 且尺寸合规 → 原样直发（省一次有损转码）
        if isJPEG(data), let dimensions = jpegDimensions(data),
           max(dimensions.width, dimensions.height) <= maxLongEdge, data.count <= maxEncodedBytes {
            return LLMImage(data: data, mimeType: "image/jpeg",
                            pixelWidth: dimensions.width, pixelHeight: dimensions.height)
        }
        let image = try decode(data)
        return try encode(cgImage: image)
    }

    /// CGImage → 合规 JPEG 图片（截图路径走这里：`CaptureEngine.currentFrameCG`）
    static func encode(cgImage: CGImage) throws -> LLMImage {
        guard cgImage.width > 0, cgImage.height > 0 else {
            throw LLMError(kind: .badResponse, message: "CGImage 尺寸非法：\(cgImage.width)×\(cgImage.height)")
        }
        guard let scaled = scale(cgImage) else {
            throw LLMError(kind: .badResponse, message: "图片缩放失败（\(cgImage.width)×\(cgImage.height)）")
        }
        let jpeg = try encodeJPEG(scaled, quality: jpegQuality)
        guard jpeg.count <= maxEncodedBytes else {
            // 硬门限兜底：不"硬发"，如实报错让上层换更小图/提示用户
            throw LLMError(kind: .badResponse,
                           message: "图片压缩后仍 \(jpeg.count) 字节（上限 \(maxEncodedBytes)）；"
                                  + "原图 \(cgImage.width)×\(cgImage.height)")
        }
        return LLMImage(data: jpeg, mimeType: "image/jpeg",
                        pixelWidth: scaled.width, pixelHeight: scaled.height)
    }

    // MARK: 缩放与编码

    /// 长边降到 `maxLongEdge`；顺带把带 alpha 的图落到不透明白底（JPEG 不支持 alpha，
    /// 直接编码会让透明区域变黑，观感与真实屏幕不符）。
    static func scale(_ image: CGImage, maxLongEdge: Int = maxLongEdge) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let longEdge = max(width, height)
        let hasAlpha = !isOpaque(image)
        if longEdge <= maxLongEdge && !hasAlpha { return image }
        var targetWidth = width
        var targetHeight = height
        if longEdge > maxLongEdge {
            let factor = Double(maxLongEdge) / Double(longEdge)
            targetWidth = max(1, Int((Double(width) * factor).rounded()))
            targetHeight = max(1, Int((Double(height) * factor).rounded()))
        }
        return render(image, width: targetWidth, height: targetHeight)
    }

    /// 画进 opaque RGB 位图（不用 NSImage/NSBitmapImageRep：不依赖 AppKit，也不碰主线程）
    static func render(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func encodeJPEG(_ image: CGImage, quality: Double = jpegQuality) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData,
                                                                 "public.jpeg" as CFString, 1, nil) else {
            throw LLMError(kind: .badResponse, message: "无法创建 JPEG 编码器")
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LLMError(kind: .badResponse, message: "JPEG 编码失败")
        }
        return output as Data
    }

    static func decode(_ data: Data) throws -> CGImage {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            throw LLMError(kind: .badResponse, message: "图片无法解码（\(data.count) 字节）")
        }
        return image
    }

    // MARK: 判据小工具（纯函数）

    static func isJPEG(_ data: Data) -> Bool {
        data.count > 3 && data[data.startIndex] == 0xFF
            && data[data.startIndex + 1] == 0xD8 && data[data.startIndex + 2] == 0xFF
    }

    static func isPNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        guard data.count > 8 else { return false }
        return Array(data.prefix(4)) == signature
    }

    /// 是否像 HTML/JSON 错误页（上游把错误页当图片回，是实测踩过的坑）
    static func isHTML(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(512), encoding: .utf8) else { return false }
        let lower = head.lowercased()
        return lower.contains("<html") || lower.contains("<!doctype html") || lower.contains("<body")
    }

    /// 从 HTML 里抠出 og:image（上游给的字段是 HTML 页面而不是图片时用）
    static func extractImageURL(from html: String) -> String? {
        let patterns = ["property=\"og:image\" content=\"", "property='og:image' content='"]
        for pattern in patterns {
            guard let range = html.range(of: pattern) else { continue }
            let rest = html[range.upperBound...]
            let opener: Character = pattern.hasSuffix("'") ? "'" : "\""
            guard let end = rest.firstIndex(of: opener) else { continue }
            let candidate = String(rest[..<end])
            if candidate.hasPrefix("http") { return candidate }
        }
        // 反序属性：og:image 写在 content 之后
        if let contentRange = html.range(of: "name=\"og:image\"") ?? html.range(of: "property=\"og:image\"") {
            let head = html[..<contentRange.lowerBound]
            if let endQuote = head.lastIndex(of: "\""),
               let startQuote = head[..<endQuote].lastIndex(of: "\"") {
                let candidate = String(head[head.index(after: startQuote)..<endQuote])
                if candidate.hasPrefix("http") { return candidate }
            }
        }
        return nil
    }

    static func stripDataURLPrefix(_ text: String) -> String {
        guard let range = text.range(of: "base64,") else { return text }
        return String(text[range.upperBound...])
    }

    static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return true
        default: return false
        }
    }

    static func jpegDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// 非图片内容的最终报错：直接把前几个字节讲给用户听，不糊弄
    static func throwNonImage(_ data: Data, mimeType: String?) throws -> Never {
        let head = String(data: data.prefix(120), encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ") ?? "(非文本)"
        let declared = mimeType.map { "声明类型 \($0)，" } ?? ""
        throw LLMError(kind: .badResponse,
                       message: "\(declared)实际内容不是图片（\(data.count) 字节）：\(head)")
    }
}

/// 同步下载的线程安全盒子（`prepare(urlString:)` 用；NSLock 保护，绝不跨线程裸读）
private final class ImageFetchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data?
    private var storedStatus: Int?
    private var storedMimeType: String?
    private var storedError: Error?

    func store(data: Data?, response: HTTPURLResponse?, error: Error?) {
        lock.lock()
        storedData = data
        storedStatus = response?.statusCode
        storedMimeType = response?.mimeType
        storedError = error
        lock.unlock()
    }

    var data: Data? { lock.lock(); defer { lock.unlock() }; return storedData }
    var status: Int? { lock.lock(); defer { lock.unlock() }; return storedStatus }
    var mimeType: String? { lock.lock(); defer { lock.unlock() }; return storedMimeType }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
}

// MARK: - URLSession 池（独立 configuration，绝不与 captureQueue 共用）

/// 会话池：按 (空闲超时, UA) 复用 session，最多 16 个。
///
/// 【为什么独立】task-2 第 10 条性能红线：传输层的连接池不能和采集/面板共用，
/// 否则一次慢请求会占住连接、拖累 30fps 采集链路（ABBA 性能对照项）。
///
/// 【为什么按空闲超时分组】候选链换渠道时超时可能不同；且 `timeoutIntervalForRequest`
/// 只能在 configuration 上设，不能逐请求改（逐请求改会被 URLSession 忽略）。
enum LLMSessionPool {

    static let maxSessions = 16
    static let defaultUserAgent = "AuroraDrive/1.0 (macOS; LLMTransport)"

    nonisolated(unsafe) private static var cache: [String: URLSession] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    private static let lock = NSLock()

    static func session(idleTimeout: TimeInterval,
                        userAgent: String = defaultUserAgent) -> URLSession {
        let seconds = max(5, idleTimeout)
        let key = "\(Int(seconds.rounded()))|\(userAgent)"
        lock.lock()
        if let existing = cache[key] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        // 【空闲超时语义】URLSessionConfiguration.timeoutIntervalForRequest 是
        // 「两个数据包之间的最大间隔」，不是整段生成的总时长 —— 正是流式需要的语义。
        configuration.timeoutIntervalForRequest = seconds
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        let session = URLSession(configuration: configuration)

        lock.lock()
        if let existing = cache[key] {
            lock.unlock()
            return existing
        }
        cache[key] = session
        order.append(key)
        while order.count > maxSessions, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        lock.unlock()
        return session
    }
}

// MARK: - OpenAI 兼容传输实现

/// OpenAI 兼容传输（无状态：每个请求自带 baseURL/apiKey）。
/// 覆盖 OVH 匿名 / Zen / Pollinations(新旧) / 智谱 / Groq / OpenRouter / 用户自定义端点。
struct OpenAICompatibleTransport: LLMTransport {

    let baseURL: String
    let apiKey: String?
    let extraHeaders: [String: String]
    let timeout: TimeInterval
    let providerName: String
    let userAgent: String

    init(baseURL: String, apiKey: String?, extraHeaders: [String: String],
         timeout: TimeInterval, providerName: String,
         userAgent: String = LLMSessionPool.defaultUserAgent) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
        self.timeout = timeout
        self.providerName = providerName
        self.userAgent = userAgent
    }

    func complete(_ req: LLMRequest) async throws -> LLMCompletion {
        // 非流式路径：走同一份 SSE/JSON 解析代码（口径一致，避免两套解析各说各话）
        try await LLMRequestRunner.run(req, base: self, streaming: false, onEvent: nil)
    }

    func stream(_ req: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await LLMRequestRunner.run(req, base: self, streaming: true) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    // 取消也走 finish(throwing:) —— 上层据 error.kind == .cancelled 识别
                    continuation.finish(throwing: LLMError.map(error, context: "流式请求"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - 请求执行（组包 → 发送 → 分类 → 解析）

enum LLMRequestRunner {

    /// 流式读取时按行 flush：单个字节就够判断一个 SSE 事件边界。
    static let streamFlushThreshold = 1

    /// 发一次请求。
    /// - Parameters:
    ///   - streaming: true → `stream: true` + `bytes(for:)` 流式消费；false → 一次性 JSON。
    ///   - onEvent: 流式回调（在 URLSession 的 async 上下文调用，**不在主线程**）
    static func run(_ request: LLMRequest,
                    base: OpenAICompatibleTransport,
                    streaming: Bool,
                    onEvent: (@Sendable (LLMStreamEvent) -> Void)?) async throws -> LLMCompletion {
        // 取消判定统一出口：**对外一律抛 LLMError(.cancelled)**，
        // 而不是裸 CancellationError —— 上游（W3/W7）按 `error as? LLMError` 分派，
        // 混着两种形状会让「取消」被误记成模型失败。
        if Task.isCancelled { throw LLMError.cancelledError() }

        // 本地校验 ①：需 key 渠道没给 key → .missingKey（**不发请求**，不浪费配额）
        if request.requiresKey, (request.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LLMError(kind: .missingKey,
                           message: "渠道需要 API Key 但未配置（\(request.providerName.isEmpty ? request.model : request.providerName)）")
        }

        // 本地校验 ②：视觉请求必须有图（不静默降级，如实报错）
        if request.vision && !request.messages.contains(where: \.hasImages) {
            throw LLMError(kind: .badResponse,
                           message: "视觉请求但消息里没有图片（不静默降级：请先编码截图或关闭视觉开关）")
        }

        let urlRequest = try makeURLRequest(request, base: base, streaming: streaming)
        let session = LLMSessionPool.session(idleTimeout: request.timeout, userAgent: base.userAgent)
        let label = request.providerName.isEmpty ? base.providerName : request.providerName

        do {
            if streaming {
                return try await runStreaming(urlRequest, request: request, session: session,
                                              label: label, onEvent: onEvent)
            }
            return try await runOnce(urlRequest, request: request, session: session, label: label)
        } catch {
            let mapped = LLMError.map(error, context: label)
            if mapped.kind == .cancelled {
                // 取消不做任何日志噪音，也不换候选（W7/W3 按 kind == .cancelled 跳过记账）
                throw mapped
            }
            log("❌ \(label)/\(request.model) \(mapped.kind.rawValue)：\(mapped.message)")
            throw mapped
        }
    }

    // MARK: 组包

    /// {base}/chat/completions（与既有 callLLM 的归一化规则一致：
    /// base 末尾去 `/`；已含 `/v1` 不再重复拼接；已含完整路径则原样用）
    static func endpointURL(for rawBase: String) -> URL? {
        var base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") { return URL(string: base) }
        if !base.hasSuffix("/v1") { base += "/v1" }
        return URL(string: base + "/chat/completions")
    }

    static func makeURLRequest(_ request: LLMRequest,
                               base: OpenAICompatibleTransport,
                               streaming: Bool) throws -> URLRequest {
        guard let url = endpointURL(for: request.baseURL) else {
            throw LLMError(kind: .badResponse, message: "BaseURL 无效：\(request.baseURL)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(base.userAgent, forHTTPHeaderField: "User-Agent")
        // 认证：空 = 不带（免 key 渠道）；Zen 的 `Bearer public` 由 W1 描述符放进 extraHeaders
        if let key = request.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in base.extraHeaders { urlRequest.setValue(value, forHTTPHeaderField: name) }
        for (name, value) in request.extraHeaders { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = try makeBody(request, streaming: streaming)
        urlRequest.timeoutInterval = max(5, request.timeout)
        return urlRequest
    }

    /// 请求体。字段顺序无关紧要，但**字段集合**很讲究：
    ///  · 不发 `stream_options`：老渠道（Pollinations legacy 等）会 400（实测踩坑）
    ///  · 空 tools 不发 `tools` 键：部分渠道对空数组直接 400
    static func makeBody(_ request: LLMRequest, streaming: Bool) throws -> Data {
        var body: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map { $0.openAIDictionary() },
            "stream": streaming,
            "temperature": request.temperature,
        ]
        if let maxTokens = request.maxTokens, maxTokens > 0 { body["max_tokens"] = maxTokens }
        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = tools.map { $0.openAIDictionary() }
        }
        guard JSONSerialization.isValidJSONObject(body) else {
            throw LLMError(kind: .badResponse, message: "请求体含不可序列化字段（model=\(request.model)）")
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: 非流式

    static func runOnce(_ urlRequest: URLRequest, request: LLMRequest,
                        session: URLSession, label: String) async throws -> LLMCompletion {
        let (data, response) = try await session.data(for: urlRequest)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw LLMError(kind: .network, message: "响应不是 HTTP（\(type(of: response))）")
        }
        let status = http.statusCode
        guard (200...299).contains(status) else {
            throw LLMError.classify(status: status, body: data,
                                    retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                                    effectiveURL: http.url?.absoluteString)
        }

        var accumulator = LLMStreamAccumulator()
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           root["choices"] != nil || root["error"] != nil {
            // 标准非流式响应
            let parsed = SSEParser.parse(chunk: data)
            if let error = parsed.error { throw error }
            accumulator.noteChunk(parsed)
        } else {
            // 个别免 key 端点会包一层 SSE（同一份解析器兜住）
            var state = SSEStreamState()
            var parses = SSEParser.consume(&state, chunk: data)
            parses.append(contentsOf: SSEParser.finish(&state))
            guard !parses.isEmpty else {
                throw LLMError(kind: .badResponse,
                               message: "响应无法解析为 OpenAI 兼容 JSON（HTTP \(status)，"
                                      + "\(data.count) 字节）", httpStatus: status)
            }
            for parse in parses {
                if let error = parse.error { throw error }
                accumulator.noteChunk(parse)
            }
        }

        // HTTP 200 但 content 为空串（实测 space-bunny-free 会出现）→ .badResponse
        // 例外：有 toolCalls 属于合法（工具回合本来没有正文）
        try validate(accumulator: accumulator, status: status, label: label, model: request.model)
        log("✅ \(label)/\(request.model) HTTP \(status) 文本 \(accumulator.text.count) 字 "
            + "工具 \(accumulator.toolCalls.count) 个 \(accumulator.chunkCount) 片")
        return accumulator.completion
    }

    // MARK: 流式

    static func runStreaming(_ urlRequest: URLRequest, request: LLMRequest,
                             session: URLSession, label: String,
                             onEvent: (@Sendable (LLMStreamEvent) -> Void)?) async throws -> LLMCompletion {
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError(kind: .network, message: "响应不是 HTTP（\(type(of: response))）")
        }
        let status = http.statusCode

        // 4xx/5xx 时 body 是错误说明（不是 SSE），要读完才能准确分类
        guard (200...299).contains(status) else {
            var body = Data()
            var errorIterator = bytes.makeAsyncIterator()
            while let byte = try? await errorIterator.next() {
                body.append(byte)
                if body.count >= 64 * 1024 { break }
            }
            throw LLMError.classify(status: status, body: body,
                                    retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                                    effectiveURL: http.url?.absoluteString)
        }

        var state = SSEStreamState()
        var accumulator = LLMStreamAccumulator()
        var iterator = bytes.makeAsyncIterator()
        var pendingBytes = Data()
        pendingBytes.reserveCapacity(4096)

        // 内联函数：把攒到的字节喂给解析器（首字延迟最小：按行 flush）
        func flushPending() throws {
            guard !pendingBytes.isEmpty else { return }
            let chunk = pendingBytes
            pendingBytes.removeAll(keepingCapacity: true)
            for parse in SSEParser.consume(&state, chunk: chunk) {
                if let error = parse.error { throw error }
                accumulator.noteChunk(parse)
                for event in parse.events { onEvent?(event) }
            }
        }

        while true {
            try Task.checkCancellation()
            let byte: UInt8?
            do {
                byte = try await iterator.next()
            } catch {
                // 半路断流：若已经拿到内容就照收（如实标注 finishReason），否则如实报错
                if accumulator.sawContentChunk {
                    log("⚠️ \(label)/\(request.model) 流中断（已有 \(accumulator.text.count) 字）：\(error)")
                    break
                }
                throw LLMError.map(error, context: label)
            }
            guard let byte else { break }   // 流正常结束
            pendingBytes.append(byte)
            if byte == 0x0A { try flushPending() }
            if state.sawDoneSentinel { break }
        }
        try flushPending()

        for parse in SSEParser.finish(&state) {
            if let error = parse.error { throw error }
            accumulator.noteChunk(parse)
            for event in parse.events { onEvent?(event) }
        }
        try Task.checkCancellation()
        try validate(accumulator: accumulator, status: status, label: label, model: request.model)
        onEvent?(.done(accumulator.completion))
        log("✅ \(label)/\(request.model) 流式 \(accumulator.text.count) 字 "
            + "工具 \(accumulator.toolCalls.count) 个 \(accumulator.chunkCount) 片")
        return accumulator.completion
    }

    // MARK: 空响应校验

    /// 空 content 判据（task-2 第 8 条最后一条，实测 space-bunny-free 会返回空串）。
    /// 有 toolCalls 或非空 reasoning 不算空。
    static func validate(accumulator: LLMStreamAccumulator,
                         status: Int, label: String, model: String) throws {
        let text = accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoning = accumulator.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && accumulator.toolCalls.isEmpty && reasoning.isEmpty {
            throw LLMError(kind: .badResponse,
                           message: "HTTP \(status) 成功但 content 为空串（\(label)/\(model)，"
                                  + "实测 space-bunny-free 会出现；建议换模型或重试）",
                           httpStatus: status)
        }
    }

    // MARK: 日志

    /// 只写 stderr 与 os_log，不碰 UI、不碰主线程（性能红线）
    static func log(_ message: String) {
        FileHandle.standardError.write(Data(("[LLMTransport] " + message + "\n").utf8))
        os_log("LLMTransport: %{public}@", type: .info, message)
    }
}

// MARK: - 工厂（W7/W6 唯一入口）

/// 传输层工厂。**返回无状态实现**（每次请求自带 baseURL/apiKey），
/// 因此同一个实例可以跨候选/跨模型复用，不需要缓存或失效管理。
enum LLMTransportFactory {

    /// - Returns: baseURL 无效/为空时返回 nil（调用方据此换下一个候选）。
    ///   baseURL 的解析（渠道 → 端点）归 W1 描述符；本层不做渠道表，避免两处真理。
    static func make(baseURL: String,
                     apiKey: String?,
                     extraHeaders: [String: String],
                     timeout: TimeInterval,
                     providerName: String) -> (any LLMTransport)? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, LLMRequestRunner.endpointURL(for: trimmed) != nil else { return nil }
        return OpenAICompatibleTransport(baseURL: trimmed,
                                         apiKey: apiKey,
                                         extraHeaders: extraHeaders,
                                         timeout: timeout > 0 ? timeout : 60,
                                         providerName: providerName)
    }
}
