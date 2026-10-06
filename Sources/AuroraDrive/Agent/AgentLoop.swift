// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  AgentLoop.swift — 原生 Tool-Calling 端到端任务循环（零框架）
//
//  架构（用户点名的「零框架·原生 Tool-Calling」）：
//  用户一句话 → LLM 把任务拆成一系列工具调用（tool_use）→
//  AgentLoop 经 ToolRegistry 统一分发执行 → 结果回传 LLM →
//  LLM 继续规划直到任务完成。
//
//  核心设计：
//  1. 【W7 改造】规划与执行**复用新传输层与工具注册表**，与聊天路径共用一条链：
//       · 模型调用   → LLMTransport（W2）        —— 不再自带 HTTP / 手工拼 tools
//       · 可用模型   → LLMHealthMonitor（W3）    —— 候选链 + 实时记账，最多轮换 4 个
//       · 工具清单   → ToolRegistry.shared.specs()（W4）
//       · 工具执行   → ToolRegistry.shared.invoke(name:args:dryRun:)（W4）
//     旧路径 AgentSkillCenter.callLLM 不再被本文件用于规划（W6 面板过渡期可继续用）。
//  2. 与 AgentSkillCenter 解耦：AgentLoop 只做「调度」，技能执行全部走统一执行通道
//     （人类 + AI 共用），并按工具名区分技能类 / 键鼠文本类 / 观察搜索类工具。
//  3. MockLLM（内置模拟调度器）：无可用候选时也能端到端自测，
//     验证「指令→规划→执行→回传→完成」整条链路。
//
//  调用链：
//    AgentSkillCenter.sendUserMessage("帮我登录然后领奖励")
//      └─ 关键词直配失败 → AgentLoop.shared.handle(task, from: .ai)
//           └─ 候选链（W3）→ RealLLMPlanner（LLMTransport）→ [AgentToolCall]
//                └─ ToolRegistry.invoke → 结果回传
//                     └─ LLM.finalize(...) → 总结 → 完成
//
//  【弱模型防线（W7 改造中逐条保留，不许删）】
//    防线 4：一次多调用只执行第一个（防发散/重复/顺序错乱）
//    防线 5：同一技能调用次数封顶（防弱模型反复调用同一技能）
//    防线 6：总时长熔断 + 连续失败熔断
//    防线 7：上下文裁剪（只喂最近 3 步）
//    防线 8：连败 3 次 → 自动降级 MockLLM
//    防线 10：被拒绝/失败的调用必须打日志（可观测）
// ============================================================================

import Foundation

// MARK: - 工具调用协议（与 LLM tool_use 结构一致）

/// 一次工具调用。
///
/// 【字段兼容】`skillID` 语义在 W7 后放宽为「工具名」：
///   · 技能类工具 → `skill__rewards`（ToolRegistry 命名）
///   · 键位/鼠标/文本/观察/搜索类工具 → `press_key` / `mouse_click` / `web_search` …
///   · MockLLMPlanner 仍产出裸技能 id（`rewards`）——执行时统一归一化，行为不变。
/// 这样既复用 W4 的注册表命名，又保持 AIAgentPanel 既有 `AgentToolCall(id:skillID:args:)`
/// 构造与 Codable 形状不变（AgentSkillCenter.callLLM 仍在用）。
struct AgentToolCall: Codable {
    let id: String          // 调用 ID（LLM 回传用）
    let skillID: String     // 工具名（技能类为 skill__<id>；MockLLM 允许裸技能 id）
    let args: [String: String]  // 参数（键位/鼠标/文本类工具使用；技能大多无参）

    /// 技能工具前缀（与 W4 ToolRegistry 逐字对齐：skill__auto_login 等）
    static let skillPrefix = "skill__"

    /// 非技能工具名（与 W4 冻结清单一致；用于区分「技能」与「按键/鼠标/观察/搜索」）
    static let nonSkillTools: Set<String> = [
        "press_key", "hold_key", "release_key", "release_all_keys",
        "type_text",
        "mouse_move", "mouse_click", "mouse_scroll",
        "screenshot", "get_status",
        "web_search", "web_fetch",
    ]

    /// 归一化为 ToolRegistry 的工具名：
    /// `skill__x` 原样返回；已知非技能工具名原样返回；裸 `x` 补技能前缀。
    var registryToolName: String {
        if skillID.hasPrefix(Self.skillPrefix) { return skillID }
        if Self.nonSkillTools.contains(skillID) { return skillID }
        return Self.skillPrefix + skillID
    }

    /// 裸技能 id（非技能工具返回 nil）——用于查 AgentSkillLibrary 的中文名与三重校验。
    var bareSkillID: String? {
        if skillID.hasPrefix(Self.skillPrefix) {
            return String(skillID.dropFirst(Self.skillPrefix.count))
        }
        return Self.nonSkillTools.contains(skillID) ? nil : skillID
    }
}

/// 工具执行结果
struct AgentToolResult: Codable {
    let id: String
    let skillID: String
    let ok: Bool
    let summary: String     // 执行摘要（回传给 LLM）
    /// 本次注入的 CGEvent 数（W4 `ToolResult.postedEvents`；A2/A3 证据字段）。
    var postedEvents: Int? = nil
}

// MARK: - LLM 规划器协议

/// 规划器：根据任务文本，产出工具调用序列
protocol AgentPlanner {
    /// 第一步：把任务拆成工具调用序列
    func plan(task: String) async -> [AgentToolCall]
    /// 中间步：根据之前的执行结果，决定下一步调用
    func nextStep(task: String, history: [AgentToolResult]) async -> AgentToolCall?
    /// 收尾：所有工具执行完后，生成最终总结
    func finalize(task: String, history: [AgentToolResult]) async -> String
}

// MARK: - AgentLoop 主循环

/// 端到端任务循环（单例）
final class AgentLoop {

    static let shared = AgentLoop()

    /// 当前规划器：nil = 未配置（走 MockLLM 离线自测）
    var planner: AgentPlanner?

    /// 弱模型防线 8：熔断降级状态（连续 LLM 任务失败计数 + 是否处于降级中）
    /// 由 handle 内部按"任务成败"维护；handle 有 isRunning 互斥，无并发写。
    private var llmFailureStreak = 0
    private(set) var aiPlanningEnabled = true

    /// 手动恢复 AI 规划（面板"AI 规划"开关/CLI 调用此方法）
    func resetLLMDowngrade() {
        llmFailureStreak = 0
        aiPlanningEnabled = true
    }

    /// 是否正在运行任务
    private(set) var isRunning = false

    /// 最多连续工具调用步数（防模型死循环）
    private let maxSteps = 8

    /// 执行过程中的进度回调（UI 显示用）
    var onProgress: ((String) -> Void)?

    private init() {}

    /// 处理一个任务：规划 → 循环执行 → 总结
    /// - Returns: 最终总结文本
    func handle(task: String, from source: AgentInvokeSource,
                progress: @escaping (String) -> Void) async -> String {
        guard !isRunning else { return "⚠️ 已有任务在运行，请等待完成或先停止。" }
        isRunning = true
        defer { isRunning = false }

        let settings = AgentSkillCenter.shared.aiSettings

        // ── 规划器选择（W7）────────────────────────────────────────────
        // 调用前先向健康监控（W3）取候选链：候选为空 = 渠道全挂 / 无可用模型。
        // 这**不是任务失败**，只是没有模型可用 → 如实说明原因后走本地规则。
        var candidates: [LLMCandidate] = []
        if aiPlanningEnabled && settings.currentBackendUsable {
            candidates = await LLMHealthMonitor.shared.candidates(requireTools: true)
        }

        var planner: AgentPlanner
        // 弱模型防线 8：熔断降级中时即使有候选也走本地规则（零幻觉兜底）
        var usedRealLLM = false
        if !aiPlanningEnabled {
            if !settings.apiKey.isEmpty || !candidates.isEmpty {
                progress("⚠️ [LLM] AI 规划处于降级状态：本次使用本地规则规划（MockLLM，零幻觉）")
            }
            planner = MockLLMPlanner()
        } else if candidates.isEmpty {
            progress("⚠️ [LLM] 降级链无可用候选（渠道全挂或未配置，非任务失败）→ 本次使用本地规则规划")
            planner = MockLLMPlanner()
        } else {
            let tools = await ToolRegistry.shared.specs()
            planner = RealLLMPlanner(settings: settings, candidates: candidates, tools: tools)
            usedRealLLM = true
        }

        var history: [AgentToolResult] = []
        progress("🧠 \(usedRealLLM ? "正在调用 LLM 规划" : "正在离线规划")：\(task)")
        var calls = await planner.plan(task: task)

        // ── 降级链感知（W7）────────────────────────────────────────────
        // 候选**全部**失败才回退 MockLLM，并在 progress 里如实说明是渠道问题。
        // 关键：这种情况不计入防线 8 的"任务连败"（usedRealLLM 置 false）——
        // 否则一次渠道抽风会把用户永久打进本地模式，那是把渠道故障误判成模型无能。
        // 同时记下说明，最终总结里也要带上：不能只报"没找到匹配的技能"，
        // 那会让用户以为是自己任务没说清，其实是渠道挂了（如实第一）。
        var channelFallbackNote: String?
        if let real = planner as? RealLLMPlanner, real.channelExhausted {
            usedRealLLM = false
            let reason = real.failureReasonText
            channelFallbackNote = "⚠️ 无法调用模型：候选链全部失败（\(reason)）。"
                                 + "这是渠道问题，不是任务失败。以下为本地规则规划的结果："
            planner = MockLLMPlanner()
            progress("⚠️ [LLM] 候选链全部失败（\(reason)）；这是渠道问题，不是任务失败 → 本次回退本地规则规划")
            calls = await planner.plan(task: task)
        }

        guard !calls.isEmpty else {
            let summary = await planner.finalize(task: task, history: history)
            return channelFallbackNote.map { "\($0)\n\(summary)" } ?? summary
        }

        // 弱模型防线 4：单步化——模型一次返回多个调用时只执行第一个（防发散/重复/顺序错乱）
        if calls.count > 1 {
            progress("⚠️ 模型一次返回 \(calls.count) 个调用，只执行第一个（防发散）")
            calls = [calls[0]]
        }

        // 循环执行：先跑 plan 的序列，然后 nextStep 补后续，直到完成或超步
        var executed: [AgentToolCall] = []
        var steps = 0
        // 弱模型容错防线 5/6：单技能调用次数上限 + 硬熔断（总时长/连续失败）
        var callCounts: [String: Int] = [:]
        let maxDuration: TimeInterval = 120
        let maxFailedSteps = 2
        let startTime = Date()
        var consecutiveFailures = 0
        var aborted = false

        while steps < maxSteps {
            guard !calls.isEmpty else { break }
            // 防线 6：总时长熔断
            if Date().timeIntervalSince(startTime) > maxDuration {
                progress("⏱️ 任务超过 \(Int(maxDuration))s 上限，强制终止（已执行 \(history.count) 步）")
                break
            }
            steps += 1

            // 逐个执行
            for call in calls {
                // 防线 5：同一技能调用次数封顶（防弱模型反复调用同一技能）
                let key = call.registryToolName
                let n = (callCounts[key] ?? 0) + 1
                callCounts[key] = n
                if n > 3 {
                    progress("⚠️ 技能「\(displayName(for: call))」已调用 \(n) 次，跳过（防死循环）")
                    continue
                }
                progress("⚙️ 执行技能：\(displayName(for: call))")
                let result = await execute(call: call)
                // 弱模型防线 10：可观测——被拒绝/失败的调用必须打日志（否则用户看不到"模型越界"）
                if !result.ok {
                    progress("⚠️ [LLM] \(result.summary)")
                }
                history.append(result)
                executed.append(call)
                // 防线 6：连续失败熔断
                if result.ok {
                    consecutiveFailures = 0
                } else {
                    consecutiveFailures += 1
                    if consecutiveFailures >= maxFailedSteps {
                        progress("❌ 连续 \(maxFailedSteps) 步失败，终止任务")
                        aborted = true
                        break
                    }
                }
            }
            if aborted { break }

            // 让 LLM 看结果，决定下一步（无 → 任务完成）
            // 弱模型防线 7：上下文裁剪——只喂最近 3 步（每条 summary 截断 120 字符），防弱模型丢指令 + 省 token
            if let next = await planner.nextStep(task: task, history: trimmedHistory(history)) {
                calls = [next]
            } else {
                calls = []
            }
        }

        // 弱模型防线 8：熔断统计——本任务用 LLM 且失败（中止/零执行/全被拒）→ 连败+1；
        // 连败≥3 自动降级本地规则；任务成功则清零（降级后需手动 resetLLMDowngrade 恢复）。
        // 注意：渠道全挂导致的回退不算模型失败（usedRealLLM 已置 false），不计入连败。
        if usedRealLLM {
            let allRejectedOrNone = executed.isEmpty || history.allSatisfy { !$0.ok }
            let taskFailed = aborted || allRejectedOrNone
            if taskFailed {
                llmFailureStreak += 1
                if llmFailureStreak >= 3 {
                    aiPlanningEnabled = false
                    progress("⚠️ [LLM] 连续 \(llmFailureStreak) 次规划任务失败，已自动降级为本地规则模式（可在面板重新开启 AI 规划）")
                }
            } else {
                llmFailureStreak = 0
            }
        }

        let summary = await planner.finalize(task: task, history: history)
        return summary
    }

    /// 执行一次工具调用。
    ///
    /// W7 改造：统一走 `ToolRegistry.shared.invoke(name:args:dryRun:)`（W4），
    /// 与聊天路径、CLI 自检共用同一个执行入口。
    /// 技能类工具保留原有**三重校验**（存在 + 已移植 + 未在运行），语义不变。
    private func execute(call: AgentToolCall) async -> AgentToolResult {
        let center = AgentSkillCenter.shared
        let toolName = call.registryToolName

        // 技能类工具：沿用原三重校验（模型幻觉 / 越界 / 重复调用的拦截点）
        if let bare = call.bareSkillID {
            guard let skill = AgentSkillLibrary.all.first(where: { $0.id == bare }) else {
                return AgentToolResult(id: call.id, skillID: call.skillID, ok: false,
                                       summary: "未知技能「\(bare)」（模型幻觉，已丢弃）")
            }
            guard skill.ported else {
                return AgentToolResult(id: call.id, skillID: call.skillID, ok: false,
                                       summary: "技能「\(skill.name)」尚未移植（模型越界，已拒绝）")
            }
            guard !center.runningSkills.contains(bare) else {
                return AgentToolResult(id: call.id, skillID: call.skillID, ok: false,
                                       summary: "技能「\(skill.name)」已在运行（重复调用，已跳过）")
            }
        }

        // W4 统一入口：护栏（辅助功能权限 / 游戏窗口 / OBSERVE_ONLY / dryRun）都在注册表内，
        // 失败一律返回 ok=false + 中文原因，不静默失败。
        let result = await ToolRegistry.shared.invoke(name: toolName, args: call.args, dryRun: false)

        let summary: String
        if result.ok {
            let base = result.text.isEmpty ? "技能「\(displayName(for: call))」已启动" : result.text
            summary = result.postedEvents > 0 ? "\(base)（注入 \(result.postedEvents) 个事件）" : base
        } else {
            summary = result.text.isEmpty ? "工具「\(toolName)」调用失败" : result.text
        }
        return AgentToolResult(id: call.id, skillID: call.skillID, ok: result.ok,
                               summary: summary, postedEvents: result.postedEvents)
    }

    /// 弱模型防线 7：历史裁剪——只保留最近 3 步，每条 summary 截断 120 字符。
    /// 模型不需要知道全部历史，只需要"刚刚发生了什么"；同时省 token。
    private func trimmedHistory(_ history: [AgentToolResult]) -> [AgentToolResult] {
        let recent = Array(history.suffix(3))
        return recent.map { r in
            AgentToolResult(id: r.id, skillID: r.skillID, ok: r.ok,
                            summary: String(r.summary.prefix(120)))
        }
    }

    /// 展示名：技能类工具查 AgentSkillLibrary 中文名，其他工具用工具名。
    private func displayName(for call: AgentToolCall) -> String {
        guard let bare = call.bareSkillID else { return call.registryToolName }
        return AgentSkillLibrary.all.first(where: { $0.id == bare })?.name ?? bare
    }
}

// MARK: - MockLLMPlanner（离线自测规划器）

/// 模拟 LLM：根据任务关键词做确定性技能规划。
/// 与真实 LLM 走完全相同的 tool_use 协议，用于无可用候选时验证整条链路。
final class MockLLMPlanner: AgentPlanner {

    /// 任务 → 技能序列 的规则表（优先级从高到低）
    private let rules: [(keywords: [String], skills: [String])] = [
        (["领奖励", "领奖", "领取"], ["rewards"]),
        (["收家具", "收一收", "收取"], ["furniture"]),
        (["登录", "进游戏", "上线"], ["auto_login"]),
        (["排球"], ["volleyball"]),
        (["钓鱼", "钓个鱼"], ["fishing"]),
        (["咖啡"], ["coffee"]),
        (["钢琴", "弹琴"], ["piano"]),
        (["闪避"], ["dodge"]),
        (["音游", "超强音", "节奏"], ["rhythm"]),
    ]

    func plan(task: String) async -> [AgentToolCall] {
        var calls: [AgentToolCall] = []
        for rule in rules where calls.isEmpty {
            if rule.keywords.contains(where: { task.contains($0) }) {
                calls = rule.skills.enumerated().map { i, sid in
                    AgentToolCall(id: "mock-\(sid)-\(i)", skillID: sid, args: [:])
                }
                break
            }
        }
        return calls
    }

    func nextStep(task: String, history: [AgentToolResult]) async -> AgentToolCall? {
        // Mock 模式：单轮规划即完成（无多步依赖）
        nil
    }

    func finalize(task: String, history: [AgentToolResult]) async -> String {
        if history.isEmpty {
            return "我没有找到匹配的技能。当前可用：登录、排球、领奖励、收家具（真实），钓鱼/咖啡/钢琴/闪避/超强音（待移植）。试试说「帮我领奖励」或「打排球」。"
        }
        let done = history.filter(\.ok).count
        return "任务完成：共执行 \(done) 个技能。\(history.map { "「\($0.summary)」" }.joined(separator: "；"))"
    }
}

// MARK: - RealLLMPlanner（真实 LLM 调用 · W7 复用新传输层）

/// 真实 LLM 规划器：工具调用走 `LLMTransport`（W2），候选来自 `LLMHealthMonitor`（W3），
/// 工具清单来自 `ToolRegistry`（W4）。**本类不做 HTTP、不手工拼 tools。**
final class RealLLMPlanner: AgentPlanner {

    /// 单次任务内最多轮换的候选数（计划要求：本模型连续失败时自动换候选，最多 4 个）
    static let maxCandidateAttempts = 4

    /// 单次规划请求超时。选 30s 而非传输层默认 60s：
    /// 候选最多 4 个，若每个都等满 60s，用户会以为面板卡死（性能红线：不阻塞）。
    static let requestTimeout: TimeInterval = 30

    private let settings: AgentSettings
    private let candidates: [LLMCandidate]
    private let tools: [LLMToolSpec]

    /// 当前候选下标：成功后**粘住**（同任务后续步骤继续用同一个模型，避免反复跳）
    private var activeIndex = 0
    /// 最近一次真实可用的候选（finalize 如实报告用）
    private(set) var lastUsedCandidate: LLMCandidate?
    /// 候选链是否已全部失败
    private(set) var channelExhausted = false
    /// 已试到的候选下标（用于区分「走完链」与「撞上 4 次上限」）
    private var lastTriedIndex = 0
    /// 是否把候选链走到了尽头（false = 撞上限，后面还有没试过的）
    private var triedToEnd = false
    /// 失败原因（逐条如实记录，给 progress 用）
    private(set) var failureReasons: [String] = []

    var failureReasonText: String {
        let reasons = failureReasons.isEmpty ? "无可用候选" : failureReasons.joined(separator: "；")
        // 撞上限时如实说明还有候选项未尝试，不谎报"全部失败"
        if !triedToEnd && !failureReasons.isEmpty {
            return "已试 \(failureReasons.count) 个候选均失败（达到单轮 \(Self.maxCandidateAttempts) 个上限，"
                 + "链上还剩 \(max(0, candidates.count - lastTriedIndex)) 个未尝试）：\(reasons)"
        }
        return reasons
    }

    init(settings: AgentSettings, candidates: [LLMCandidate], tools: [LLMToolSpec]) {
        self.settings = settings
        self.candidates = candidates
        self.tools = tools
    }

    // MARK: AgentPlanner

    func plan(task: String) async -> [AgentToolCall] {
        await run(messages: Self.buildMessages(task: task, history: nil))
    }

    func nextStep(task: String, history: [AgentToolResult]) async -> AgentToolCall? {
        guard !history.isEmpty else { return nil }
        let calls = await run(messages: Self.buildMessages(task: task, history: history))
        return calls.first
    }

    func finalize(task: String, history: [AgentToolResult]) async -> String {
        if channelExhausted {
            // 如实说明：是渠道全挂，不是任务失败（用户对编数据/糊弄零容忍）
            return "⚠️ 无法调用模型：候选链全部失败（\(failureReasonText)）。\n"
                 + "这是渠道问题，不是任务失败；本次未执行任何需要模型的步骤。"
                 + (history.isEmpty ? "" : "\n已执行 \(history.filter(\.ok).count) 个步骤。")
        }
        if history.isEmpty {
            return "LLM 未返回任何工具调用。当前可用：登录、排球、领奖励、收家具（真实）。"
        }
        let done = history.filter(\.ok).count
        let model = lastUsedCandidate.map { "\($0.backend.displayName)/\($0.model)" } ?? settings.model
        return "LLM 完成任务：共调用 \(done) 个工具（模型 \(model)）。\n"
             + history.map { "- \($0.summary)" }.joined(separator: "\n")
    }

    // MARK: 单次请求（含候选轮换）

    /// 发一次请求，失败则按候选链轮换（最多 `maxCandidateAttempts` 个），
    /// 每次结果都回写 `LLMHealthMonitor`（noteSuccess / noteFailure）——
    /// 真实请求即探活，这是 W3 设计里最可信的健康证据。
    private func run(messages: [LLMMessage]) async -> [AgentToolCall] {
        var attempted = 0
        var cancelled = false
        var index = min(activeIndex, max(0, candidates.count - 1))
        while attempted < Self.maxCandidateAttempts && index < candidates.count {
            let candidate = candidates[index]
            attempted += 1
            let started = Date()
            do {
                guard let transport = Self.makeTransport(candidate: candidate, settings: settings) else {
                    failureReasons.append("\(candidate.backend.displayName)/\(candidate.model)：无法构建传输层"
                                          + "（渠道不可用\(candidate.backend.requiresKey ? "或缺少 API Key" : "")）")
                    lastTriedIndex = index + 1
                    index += 1
                    continue
                }
                let completion = try await transport.complete(
                    LLMRequest(baseURL: Self.baseURL(for: candidate, settings: settings),
                               model: candidate.model,
                               apiKey: Self.apiKey(for: candidate, settings: settings),
                               messages: messages,
                               tools: tools,
                               stream: false,
                               temperature: Self.temperature(settings.thinkingDepth),
                               maxTokens: 1024,
                               extraHeaders: Self.extraHeaders(for: candidate, settings: settings),
                               providerName: candidate.backend.displayName,
                               timeout: Self.requestTimeout))
                let latencyMs = Date().timeIntervalSince(started) * 1000
                await LLMHealthMonitor.shared.noteSuccess(candidate, latencyMs: latencyMs)
                activeIndex = index
                lastUsedCandidate = candidate
                channelExhausted = false
                triedToEnd = false
                return Self.toolCalls(from: completion)
            } catch {
                // 取消不是模型问题：不记账、不换候选、不误报"渠道全挂"
                if Self.isCancellation(error) {
                    await LLMHealthMonitor.shared.noteFailure(candidate, error: error)
                    cancelled = true
                    break
                }
                await LLMHealthMonitor.shared.noteFailure(candidate, error: error)
                failureReasons.append("\(candidate.backend.displayName)/\(candidate.model)：\(Self.describe(error))")
                lastTriedIndex = index + 1
                index += 1
            }
        }
        // 如实区分两种情况：**走完候选链**（候选真全挂）vs **撞到 4 次上限**
        // （后面还有没试过的候选）。后者若也报"全部失败"就是撒谎。
        triedToEnd = !cancelled && lastTriedIndex >= candidates.count
        channelExhausted = !cancelled
        if cancelled || channelExhausted { lastUsedCandidate = nil }
        return []
    }

    // MARK: 渠道适配（本文件唯一依赖 W1/W2 API 形状的地方）

    /// 取渠道描述符。**全文件只有这里依赖 W1 的 API 形状**，W1 签名若有出入只改这个函数。
    /// W1 `LLMBackendRegistry.shared.descriptor(for:baseURLOverride:)`：对 8 个 case 均返回
    /// 非 nil，故兜底分支只在极端情况下触发（用出厂设置拼一个最小描述符语义）。
    private static func descriptor(for kind: LLMBackendKind,
                                   settings: AgentSettings) -> LLMBackendDescriptor? {
        LLMBackendRegistry.shared.descriptor(for: kind, baseURLOverride: settings.baseUrl)
    }

    /// 渠道基址：`.userKey` 由 W1 描述符按 override 返回用户端点，其余为渠道实测地址。
    /// 拿不到描述符时回退 `settings.baseUrl`（老配置路径，行为与改造前一致）。
    private static func baseURL(for candidate: LLMCandidate, settings: AgentSettings) -> String {
        let fromDescriptor = descriptor(for: candidate.backend, settings: settings)?.baseURL ?? ""
        return fromDescriptor.isEmpty ? settings.baseUrl : fromDescriptor
    }

    /// 渠道附加头（Zen 的 UA / x-opencode-session / Bearer public 等由 W1 描述符给出）。
    private static func extraHeaders(for candidate: LLMCandidate, settings: AgentSettings) -> [String: String] {
        descriptor(for: candidate.backend, settings: settings)?.extraHeaders ?? [:]
    }

    /// 免 key 渠道传 nil（W2 约定：nil/空 = 不带 Authorization），需 key 渠道传用户 key。
    /// 需 key 渠道但 key 为空时返回 nil 并由 `makeTransport` 拦截（本地校验，不发请求）。
    private static func apiKey(for candidate: LLMCandidate, settings: AgentSettings) -> String? {
        guard candidate.backend.requiresKey else { return nil }
        return settings.apiKey.isEmpty ? nil : settings.apiKey
    }

    /// 按候选构造传输层（W2 `LLMTransportFactory.make`，baseURL 无效时返回 nil）。
    private static func makeTransport(candidate: LLMCandidate,
                                      settings: AgentSettings) -> (any LLMTransport)? {
        // 需 key 渠道无 key → 本地拦截（与 W2 的 .missingKey 语义一致：根本没发请求）
        if candidate.backend.requiresKey && settings.apiKey.isEmpty { return nil }
        let base = baseURL(for: candidate, settings: settings)
        guard !base.isEmpty else { return nil }
        return LLMTransportFactory.make(baseURL: base,
                                        apiKey: apiKey(for: candidate, settings: settings),
                                        extraHeaders: extraHeaders(for: candidate, settings: settings),
                                        timeout: requestTimeout,
                                        providerName: candidate.backend.displayName)
    }

    // MARK: 消息与解析

    private static func temperature(_ depth: Int) -> Double {
        // 思考深度 4 档 → temperature（想得越深，输出越收敛；与面板/旧 callLLM 同表）
        switch depth {
        case 1: return 0.9
        case 2: return 0.5
        case 3: return 0.2
        default: return 0.05
        }
    }

    /// 系统提示：与 tool calling 协议一致（不要求模型输出 JSON 文本，只用工具调用）
    private static let systemPrompt = """
    你是 AuroraDrive 的游戏助手规划器。你可以调用工具（游戏技能、按键、鼠标、文本、截图、状态、联网搜索）来完成用户任务。
    规则：
    1. 每一步只调用**一个**工具；不要一次返回多个。
    2. 只能使用工具清单里存在的工具名，不要臆造。
    3. 任务已完成时，不要再返回任何工具调用。
    """

    /// 构建 messages：系统提示 + 用户任务 + 历史工具结果（防线 7 已在调用方裁剪）
    private static func buildMessages(task: String, history: [AgentToolResult]?) -> [LLMMessage] {
        var messages: [LLMMessage] = [.system(systemPrompt), .user(task)]
        if let history, !history.isEmpty {
            let lines = history.map { "\($0.ok ? "成功" : "失败")：\($0.summary)" }.joined(separator: "\n")
            messages.append(.user("已执行结果：\n\(lines)\n请判断下一步：若任务已完成，不要再返回工具调用。"))
        }
        return messages
    }

    /// `LLMCompletion` → `[AgentToolCall]`。参数是 JSON 字符串，转成 `[String: String]`
    /// （W4 的 args 全为 String，数字按字符串传，由其内部解析与范围校验）。
    private static func toolCalls(from completion: LLMCompletion) -> [AgentToolCall] {
        completion.toolCalls.map { call in
            AgentToolCall(id: call.id, skillID: call.name, args: parseArguments(call.argumentsJSON))
        }
    }

    /// 解析工具参数 JSON → `[String: String]`（标量转字符串；嵌套值保留 JSON 文本）
    static func parseArguments(_ json: String) -> [String: String] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case let s as String: out[key] = s
            case let n as NSNumber: out[key] = n.stringValue
            default:
                if let nested = try? JSONSerialization.data(withJSONObject: value),
                   let text = String(data: nested, encoding: .utf8) {
                    out[key] = text
                }
            }
        }
        return out
    }

    /// 取消判定：Task.cancel 或 W2 的 `.cancelled` 错误类。
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let llmError = error as? LLMError, llmError.kind == .cancelled { return true }
        return false
    }

    /// 失败原因（如实展示上游原话，不糊弄）
    private static func describe(_ error: Error) -> String {
        if let llmError = error as? LLMError {
            return "\(llmError.kind)（\(llmError.message)）"
        }
        if error is CancellationError { return "已取消" }
        return "\(error)"
    }
}
