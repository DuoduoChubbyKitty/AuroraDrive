// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  AgentLoop.swift — 原生 Tool-Calling 端到端任务循环（零框架）
//
//  架构（用户点名的「零框架·原生 Tool-Calling」）：
//  用户一句话 → LLM 把任务拆成一系列技能调用（tool_use）→
//  AgentLoop 逐个执行 AgentSkillCenter 的技能 → 结果回传 LLM →
//  LLM 继续规划直到任务完成。
//
//  核心设计：
//  1. 与 AgentSkillCenter 完全解耦：AgentLoop 只做「调度」，技能执行
//     全部走既有的统一执行通道（人类 + AI 共用）。
//  2. 工具协议（ToolProtocol）与真实 LLM 的 tool_use 一致，
//     方便将来接 DeepSeek/GPT/Claude 任意一家。
//  3. MockLLM（内置模拟调度器）：无 API key 也能端到端自测，
//     验证「指令→规划→执行→回传→完成」整条链路；有 key 时自动用真模型。
//
//  调用链：
//    AgentSkillCenter.sendUserMessage("帮我登录然后领奖励")
//      └─ 关键词直配失败 → AgentLoop.shared.handle(task, from: .ai)
//           └─ MockLLM / RealLLM.plan(task) → [ToolCall]
//                └─ 逐个执行 execute(toolCall) → 结果回传
//                     └─ LLM.finalize(...) → 总结 → 完成
// ============================================================================

import Foundation

// MARK: - 工具调用协议（与 LLM tool_use 结构一致）

/// 一次技能调用
struct AgentToolCall: Codable {
    let id: String          // 调用 ID（LLM 回传用）
    let skillID: String     // 技能 ID（与 AgentSkillLibrary 对应）
    let args: [String: String]  // 参数（当前技能大多无参，预留）
}

/// 技能执行结果
struct AgentToolResult: Codable {
    let id: String
    let skillID: String
    let ok: Bool
    let summary: String     // 执行摘要（回传给 LLM）
}

// MARK: - LLM 规划器协议

/// 规划器：根据任务文本，产出技能调用序列
protocol AgentPlanner {
    /// 第一步：把任务拆成技能调用序列
    func plan(task: String) async -> [AgentToolCall]
    /// 中间步：根据之前的执行结果，决定下一步调用
    func nextStep(task: String, history: [AgentToolResult]) async -> AgentToolCall?
    /// 收尾：所有技能执行完后，生成最终总结
    func finalize(task: String, history: [AgentToolResult]) async -> String
}

// MARK: - AgentLoop 主循环

/// 端到端任务循环（单例）
final class AgentLoop {

    static let shared = AgentLoop()

    /// 当前规划器：nil = 未配置（走 MockLLM 离线自测）
    var planner: AgentPlanner?

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

        // 优先用真实 LLM（有 API Key），否则回退 MockLLM
        let center = AgentSkillCenter.shared
        let hasAPIKey = !center.aiSettings.apiKey.isEmpty
        let planner: AgentPlanner = hasAPIKey ? RealLLMPlanner(center: center) : MockLLMPlanner()

        var history: [AgentToolResult] = []
        progress("🧠 \(hasAPIKey ? "正在调用 LLM 规划" : "正在离线规划")：\(task)")
        var calls = await planner.plan(task: task)

        guard !calls.isEmpty else {
            let summary = await planner.finalize(task: task, history: history)
            return summary
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
                let n = (callCounts[call.skillID] ?? 0) + 1
                callCounts[call.skillID] = n
                if n > 3 {
                    progress("⚠️ 技能「\(skillName(call.skillID))」已调用 \(n) 次，跳过（防死循环）")
                    continue
                }
                progress("⚙️ 执行技能：\(skillName(call.skillID))")
                let result = execute(call: call)
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

        let summary = await planner.finalize(task: task, history: history)
        return summary
    }

    /// 执行一次技能调用（走 AgentSkillCenter 统一通道）
    private func execute(call: AgentToolCall) -> AgentToolResult {
        let center = AgentSkillCenter.shared
        guard let skill = AgentSkillLibrary.all.first(where: { $0.id == call.skillID }) else {
            return AgentToolResult(id: call.id, skillID: call.skillID, ok: false,
                                   summary: "未知技能「\(call.skillID)」（模型幻觉，已丢弃）")
        }
        // 三重校验：存在 + 已移植 + 未在运行
        guard skill.ported else {
            return AgentToolResult(id: call.id, skillID: call.skillID, ok: false,
                                   summary: "技能「\(skill.name)」尚未移植（模型越界，已拒绝）")
        }
        guard !center.runningSkills.contains(call.skillID) else {
            return AgentToolResult(id: call.id, skillID: call.skillID, ok: false,
                                   summary: "技能「\(skill.name)」已在运行（重复调用，已跳过）")
        }
        // 记录执行前消息数，执行后取新增消息做摘要
        let before = center.messages.count
        center.runSkill(call.skillID, source: .ai)
        // 简单等待技能启动（真实异步执行，这里给 0.6s 让 start 日志落进 messages）
        Thread.sleep(forTimeInterval: 0.6)
        let newMessages = center.messages.dropFirst(before).map(\.text)
        let summary = newMessages.isEmpty
            ? "技能「\(skillName(call.skillID))」已启动"
            : newMessages.joined(separator: "；")
        return AgentToolResult(id: call.id, skillID: call.skillID, ok: true, summary: summary)
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

    private func skillName(_ id: String) -> String {
        AgentSkillLibrary.all.first(where: { $0.id == id })?.name ?? id
    }
}

// MARK: - MockLLMPlanner（离线自测规划器）

/// 模拟 LLM：根据任务关键词做确定性技能规划。
/// 与真实 LLM 走完全相同的 tool_use 协议，用于无 key 时验证整条链路。
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

// MARK: - RealLLMPlanner（真实 LLM 调用）

/// 真实 LLM 规划器：通过 OpenAI 兼容 API 调用云端模型
final class RealLLMPlanner: AgentPlanner {
    private let center: AgentSkillCenter

    init(center: AgentSkillCenter) {
        self.center = center
    }

    func plan(task: String) async -> [AgentToolCall] {
        await center.callLLM(task: task, history: [])
    }

    func nextStep(task: String, history: [AgentToolResult]) async -> AgentToolCall? {
        guard !history.isEmpty else { return nil }
        let calls = await center.callLLM(task: task, history: history)
        return calls.first
    }

    func finalize(task: String, history: [AgentToolResult]) async -> String {
        if history.isEmpty {
            return "LLM 未返回任何技能调用。当前可用：登录、排球、领奖励、收家具（真实）。"
        }
        let done = history.filter(\.ok).count
        return "LLM 完成任务：共调用 \(done) 个技能。\n" + history.map { "- \($0.summary)" }.joined(separator: "\n")
    }
}
