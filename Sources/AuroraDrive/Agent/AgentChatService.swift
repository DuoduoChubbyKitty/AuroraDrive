// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  AgentChatService.swift — 聊天粘合层（W6a · 2026-10-06）
// ============================================================================
//
//  【为什么需要这一层】
//    面板（AIAgentPanel）要的是「用户说一句话 → 边收边显示 → 得到最终文本」，
//    而下面那套是「候选链 × 传输层 × 健康监控」的分布式状态。把这段编排
//    独立成 actor，好处有三个：
//      · 面板代码不必知道候选/降级/错误分类的细节（UI 只关心文本与状态串）
//      · 编排逻辑可被 CLI 自检直接复用（--llm-selftest 与面板同一条路径）
//      · 网络与解析全部留在 actor 内，**绝不碰主线程**（性能红线）
//
//  【它解决的病根】
//    改造前：`sendUserMessage` 的自由文本分支走 `localReply()` 硬编码套话，
//    真正的模型问答函数 `plainAnswer` 写好了却**从未被生产路径调用**。
//    本文件就是那条缺失的生产路径。
//
//  【降级语义】
//    候选链来自 W3 `LLMHealthMonitor.candidates`，**最多尝试 4 个**
//    （避免"降级风暴"把一次对话拖成十几次网络往返）。
//    全链失败**不抛错给 UI**：返回空文本 + 错误串，由面板决定回退
//    `localReply` 并标注「离线回复」——用户能分清"模型答的"和"本地兜底"。
//
//  【性能红线（实测依据）】
//    · Vision OCR p50 33.6ms ≈ 一整个 30Hz 帧预算 → 本项目对主线程极敏感
//    · 故：网络、SSE 解析、历史裁剪全在 actor 内；`onDelta` 回调由调用方
//      自行切主线程，且**本层对增量做 ≤15Hz 节流**，避免 SwiftUI 每 token 重绘
//
// ============================================================================

import Foundation

// MARK: - 对话轮次

/// 一轮对话（历史裁剪与请求组装的输入单位）。
struct ChatTurn: Sendable, Equatable {
    var role: String      // "user" / "assistant"
    var text: String

    init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

/// 一次问答的结果。字段全部是**可展示的事实**，不含推测。
struct ChatReply: Sendable {
    /// 模型生成的正文。**空串表示本次没有拿到回复**（配合 `errorMessage` 使用）。
    var text: String
    /// 实际作答的模型（上游回显优先，其次请求所用）
    var model: String
    /// 实际作答的渠道
    var backend: LLMBackendKind
    /// 是否经过降级（当前候选 ≠ 首选候选）
    var viaFallback: Bool
    /// 本次尝试过的候选数量（诊断用）
    var attemptedCandidates: Int
    /// 失败原因（成功时为 nil）。**如实透传上游原话**，不美化。
    var errorMessage: String?
    /// token 用量（若有）
    var usage: LLMUsage?
    /// 推理内容（部分渠道给 reasoning_content；UI 可折叠展示）
    var reasoning: String?

    /// 本次是否拿到可用回复
    var ok: Bool { !text.isEmpty }

    init(text: String, model: String, backend: LLMBackendKind, viaFallback: Bool,
         attemptedCandidates: Int, errorMessage: String? = nil,
         usage: LLMUsage? = nil, reasoning: String? = nil) {
        self.text = text
        self.model = model
        self.backend = backend
        self.viaFallback = viaFallback
        self.attemptedCandidates = attemptedCandidates
        self.errorMessage = errorMessage
        self.usage = usage
        self.reasoning = reasoning
    }

    /// 全链失败时的构造（面板据此回退 localReply 并标注离线）
    static func failure(reason: String, attempted: Int) -> ChatReply {
        ChatReply(text: "", model: "-", backend: .ovhAnonymous, viaFallback: false,
                  attemptedCandidates: attempted, errorMessage: reason)
    }
}

// MARK: - 聊天粘合层

/// 自由聊天的编排层：系统提示 + 历史 + 候选链 + 流式增量 → 一段完整回复。
///
/// **无状态可重入**：所有请求参数来自 `AgentSettings.load()`（每次现读，
/// 用户改配置后下一次对话立即生效，无需重启面板）。
actor AgentChatService {

    static let shared = AgentChatService()

    private init() {}

    // MARK: 常量

    /// 历史最多保留的轮数（防 token 爆炸）。超出的旧轮次直接丢弃——
    /// 任务面板 OCR 那条链用的也是"只保留最近窗口"的思路。
    static let maxHistoryTurns = 12

    /// 降级链最多尝试的候选数。**4 是权衡值**：免费档限流时总要给几条活路，
    /// 但一次对话拖成十几次往返的体验不可接受（且会触发更多限流）。
    static let maxCandidatesPerRequest = 4

    /// 流式增量回调的最小间隔（秒）。15Hz ≈ 66ms，与 UI 刷新预算同量级。
    ///
    /// 【为什么节流】部分渠道按 token 推 SSE，一次长回答可达数百个 chunk；
    /// 每个 chunk 都触发一次 SwiftUI 状态写入会把主线程打满（本项目对主线程
    /// 极敏感：Vision OCR 33.6ms 就吃掉一整个 30Hz 帧预算）。
    static let deltaThrottleInterval: TimeInterval = 1.0 / 15.0

    /// 单次请求超时（秒）。这是**空闲超时**语义（两包之间的最大间隔），
    /// 不会把流式长回答腰斩——见 W2 `LLMRequest.timeout` 的注释。
    static let requestTimeout: TimeInterval = 30

    /// 系统提示：告诉模型它是谁、能干什么、以及**能调工具**。
    ///
    /// 【为什么写全工具能力】模型只有知道"有这些工具"才会在合适的时机调用；
    /// 工具清单本身经 function calling 的 `tools` 字段单独下发，这里写的是
    /// 行为约束（何时调、调完怎么说话）。
    static let systemPrompt = """
    你是 AuroraDrive 的 AI 助手，运行在 macOS 上的《异环》游戏辅助工具里。

    能力：
    · 正常聊天：回答用户的问题，可以闲聊、解释、给建议。
    · 调用游戏工具：你可以调用工具完成游戏内操作，包括：
      - 技能类（自动登录/排球/钓鱼/咖啡/钢琴/闪避/收家具/领奖励/抚摸/滚动等）
      - 按键类（press_key/hold_key/release_key/release_all_keys，可发 W/A/S/D/F/E/空格/ESC 等键）
      - 鼠标类（mouse_move/mouse_click/mouse_scroll）
      - 文本类（type_text，向游戏内输入文本）
      - 信息类（web_search 联网搜索、web_fetch 读网页、screenshot 看当前屏幕、get_status 查状态）
    · 看屏幕：当用户发来截图时，直接描述你看到的内容。

    规则：
    1. 需要操作游戏时**先调用工具**，不要只是口头答应。
    2. 一次只调用一个工具，拿到结果后再决定下一步。
    3. 工具的返回结果可能是"未检测到游戏窗口""权限未授权"等失败——
       这时**如实告诉用户原因**，不要假装成功。
    4. 不确定用户想要什么时，先问清楚再动手。
    5. 回答用中文，简洁直接。
    """

    // MARK: 候选链（供 UI 小字与诊断复用）

    /// 取当前可用候选链。UI 小字与诊断面板可直接用（不重复实现聚合逻辑）。
    func candidates(requireVision: Bool) async -> [LLMCandidate] {
        let settings = AgentSettings.load()
        return await LLMHealthMonitor.shared.candidates(
            preferred: settings.preferredFreeModel.isEmpty ? nil : settings.preferredFreeModel,
            requireVision: requireVision,
            requireTools: true)
    }

    // MARK: 主入口

    /// 流式对话。
    ///
    /// - Parameters:
    ///   - text: 用户这句话
    ///   - history: 之前的对话轮次（最旧的在前）；本层负责裁剪到最近 12 轮
    ///   - image: 随图提问（nil = 纯文本）。若给了图但候选链里没有视觉模型，
    ///            **如实失败**，不静默退化成纯文本（用户规格）
    ///   - onDelta: 增量文本回调。**在后台执行**，调用方自行切主线程；
    ///              本层已按 15Hz 节流
    /// - Returns: 最终结果（含实际模型/渠道/是否降级/失败原因）
    func reply(text: String,
               history: [ChatTurn],
               image: LLMImage? = nil,
               onDelta: @escaping @Sendable (String) -> Void) async -> ChatReply {

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(reason: "空输入", attempted: 0) }

        let settings = AgentSettings.load()
        let requireVision = (image != nil)

        // 1) 候选链
        let chain = await candidates(requireVision: requireVision)
        guard !chain.isEmpty else {
            return .failure(
                reason: requireVision
                    ? "当前没有可用的视觉模型（免费档视觉源有限，可在设置里配置自己的 API Key）"
                    : "没有可用模型（所有渠道均不可达或被限流）",
                attempted: 0)
        }

        // 2) 组装消息（系统提示 + 裁剪后的历史 + 本轮）
        let messages = Self.buildMessages(history: history, userText: trimmed, image: image)

        // 3) 逐个候选尝试（最多 4 个）
        var attempted = 0
        var lastError: String?
        let limit = min(Self.maxCandidatesPerRequest, chain.count)

        for index in 0..<limit {
            let candidate = chain[index]
            attempted += 1

            // 需 key 渠道但用户没配 key → 跳过（不消耗一次往返）
            if candidate.backend.requiresKey && settings.apiKey.isEmpty { continue }

            let base = Self.baseURL(for: candidate, settings: settings)
            guard !base.isEmpty else { continue }

            guard let transport = LLMTransportFactory.make(
                baseURL: base,
                apiKey: Self.apiKey(for: candidate, settings: settings),
                extraHeaders: Self.extraHeaders(for: candidate),
                timeout: Self.requestTimeout,
                providerName: candidate.backend.displayName) else { continue }

            let request = LLMRequest(
                baseURL: base,
                model: candidate.model,
                apiKey: Self.apiKey(for: candidate, settings: settings),
                messages: messages,
                tools: nil,                       // 聊天路径不带工具（工具调度走 AgentLoop）
                stream: true,
                temperature: Self.temperature(settings.thinkingDepth),
                maxTokens: 2048,
                extraHeaders: Self.extraHeaders(for: candidate),
                providerName: candidate.backend.displayName,
                timeout: Self.requestTimeout,
                vision: requireVision)

            let started = Date()
            do {
                let completion = try await Self.consumeStream(
                    transport: transport, request: request, onDelta: onDelta)
                let latencyMs = Date().timeIntervalSince(started) * 1000

                // 空正文且无推理内容 → 视为该候选失败（实测 space-bunny-free 会返回空串）
                if completion.text.isEmpty && (completion.reasoning ?? "").isEmpty {
                    await LLMHealthMonitor.shared.noteFailure(
                        candidate,
                        error: LLMError(kind: .badResponse, message: "返回空内容"))
                    lastError = "\(candidate.backend.displayName)/\(candidate.model)：返回空内容"
                    continue
                }

                await LLMHealthMonitor.shared.noteSuccess(candidate, latencyMs: latencyMs)

                return ChatReply(
                    text: completion.text,
                    model: completion.model ?? candidate.model,
                    backend: candidate.backend,
                    viaFallback: index > 0,
                    attemptedCandidates: attempted,
                    usage: completion.usage,
                    reasoning: completion.reasoning)

            } catch is CancellationError {
                return .failure(reason: "已取消", attempted: attempted)
            } catch {
                await LLMHealthMonitor.shared.noteFailure(candidate, error: error)
                lastError = Self.describe(candidate: candidate, error: error)
                continue
            }
        }

        return .failure(reason: lastError ?? "所有候选均失败", attempted: attempted)
    }

    // MARK: 流消费

    /// 消费一条流，聚合正文/推理，并按 15Hz 节流回调增量。
    ///
    /// 【W2 的实际事件集】只有 4 个 case：delta / reasoning / toolCall / done。
    /// `done` **一次性带回完整 LLMCompletion**（含 usage / finishReason / model /
    /// reasoning），所以这里以 `done` 的内容为准，流中累积的文本作为兜底
    /// （部分渠道 done 只给 usage 不给全文）。
    private static func consumeStream(transport: any LLMTransport,
                                      request: LLMRequest,
                                      onDelta: @escaping @Sendable (String) -> Void) async throws -> LLMCompletion {
        var text = ""
        var reasoning = ""
        var final: LLMCompletion?

        var lastEmit = Date.distantPast

        for try await event in transport.stream(request) {
            try Task.checkCancellation()
            switch event {
            case .delta(let piece):
                text += piece
                // 15Hz 节流：距上次回调不足 66ms 的增量攒着，下一次一起给
                let now = Date()
                if now.timeIntervalSince(lastEmit) >= deltaThrottleInterval {
                    lastEmit = now
                    onDelta(text)          // 传全量（调用方直接覆盖显示，天然幂等）
                }
            case .reasoning(let piece):
                reasoning += piece
            case .toolCall:
                // 聊天路径不消费工具调用（工具调度在 AgentLoop）
                break
            case .done(let completion):
                final = completion
            }
        }

        // 收尾：把最后一段（可能仍在节流窗口内）补发一次
        if !text.isEmpty { onDelta(text) }

        if let final {
            // done 带全量时以它为准；但若 done.text 为空而流里攒到了文本，用攒的
            let merged = final.text.isEmpty ? text : final.text
            let reasoningText = final.reasoning ?? (reasoning.isEmpty ? nil : reasoning)
            return LLMCompletion(text: merged,
                                 toolCalls: final.toolCalls,
                                 usage: final.usage,
                                 finishReason: final.finishReason,
                                 model: final.model,
                                 reasoning: reasoningText)
        }
        return LLMCompletion(text: text, toolCalls: [], usage: nil,
                             finishReason: nil, model: nil,
                             reasoning: reasoning.isEmpty ? nil : reasoning)
    }

    // MARK: 消息组装

    /// 系统提示 + 最近 N 轮历史 + 本轮用户输入（可带图）。
    private static func buildMessages(history: [ChatTurn],
                                      userText: String,
                                      image: LLMImage?) -> [LLMMessage] {
        var messages: [LLMMessage] = []
        messages.append(LLMMessage(role: "system", text: systemPrompt))

        // 历史裁剪：只保留最近 maxHistoryTurns 轮；空文本轮次直接丢弃
        let recent = history
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(maxHistoryTurns)
        for turn in recent {
            let role = (turn.role == "assistant") ? "assistant" : "user"
            messages.append(LLMMessage(role: role, text: turn.text))
        }

        // 本轮：带图时用 content 数组（W2 负责编码成 image_url part）
        if let image {
            messages.append(LLMMessage(role: "user", text: userText, images: [image]))
        } else {
            messages.append(LLMMessage(role: "user", text: userText))
        }
        return messages
    }

    // MARK: 渠道参数（与 W7/AgentLoop 同一套规则，避免两处漂移）

    /// 渠道 baseURL。userKey 用用户填的 `settings.baseUrl`；其余按渠道描述符。
    private static func baseURL(for candidate: LLMCandidate, settings: AgentSettings) -> String {
        if candidate.backend == .userKey {
            let raw = settings.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return "" }
            return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        }
        return LLMBackendRegistry.shared.descriptor(for: candidate.backend)?.baseURL ?? ""
    }

    /// 渠道 Authorization。免 key 渠道返回 nil（Zen 的 `Bearer public` 在 extraHeaders 里）。
    private static func apiKey(for candidate: LLMCandidate, settings: AgentSettings) -> String? {
        candidate.backend.requiresKey ? settings.apiKey : nil
    }

    /// 渠道自定义头（Zen 的三头在这里）
    private static func extraHeaders(for candidate: LLMCandidate) -> [String: String] {
        LLMBackendRegistry.shared.descriptor(for: candidate.backend)?.extraHeaders ?? [:]
    }

    /// 思考深度 4 档 → temperature（与面板旧 `callLLM`、W7 同一张表）
    private static func temperature(_ depth: Int) -> Double {
        switch depth {
        case 1: return 0.9
        case 2: return 0.5
        case 3: return 0.2
        default: return 0.05
        }
    }

    /// 把错误整理成**给人看的一句话**（含渠道/模型，便于用户判断是哪家出问题）
    private static func describe(candidate: LLMCandidate, error: Error) -> String {
        if let e = error as? LLMError {
            return "\(candidate.backend.displayName)/\(candidate.model)：\(e.message)"
        }
        return "\(candidate.backend.displayName)/\(candidate.model)：\(error.localizedDescription)"
    }
}
