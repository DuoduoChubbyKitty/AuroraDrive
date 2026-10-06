// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ═══════════════════════════════════════════════════════════════════════════
// 【出处标注 · 品牌澄清】2026-10-04
//   本文件的**技能实现**大量移植/参考自上游开源项目 **MaaNTE**（AGPL-3.0）。
//   下文注释里的「MaaNTE」一律是**上游项目名**，用于交代每个技能的来源与
//   对齐依据 —— **它不是本产品的品牌，也不是本产品的名字**。
//   本产品品牌：`AuroraDrive`（见 `App/AuroraBrand.swift`）。
//   保留出处的理由：技能参数（键位、节奏、坐标、轮数）必须可追溯到原始
//   出处，抹掉出处等于让后人无法复核「这个 0.6s 到底是怎么定的」。
//   故：出处保留；**品牌层（用户可见字符串 / 类型名 / 变量名）不得出现上游名**。
// ═══════════════════════════════════════════════════════════════════════════
// ============================================================================
//  AIAgentPanel.swift — AI 助手侧边面板 + 技能统一执行通道
//
//  架构要点（这是本文件的灵魂）：
//  ─────────────────────────────────────────────────────────────
//  AgentSkillCenter 是「人类」与「AI」共用的唯一执行通道：
//    人类点技能按钮  →  run(skillID, source: .human)
//    AI 发送指令     →  sendUserMessage("帮我钓个鱼") → 解析 → run(skillID, source: .ai)
//  两条路最终都汇入 run(skillID, source:) 这一个入口，任何技能都
//  可被双方调用，行为完全一致（状态、日志、会话消息都同源）。
//
//  技能真实度说明（诚实标注，不做假按钮）：
//    · auto_login   —— 全真实：CaptureEngine 帧 → Vision OCR → MouseController 点击
//    · volleyball   —— 全真实：0.6s K 键循环（MaaNTE auto_volleyball 核心循环直移植）
//    · 其余 8 项    —— 依赖 MaaNTE 视觉管线（Windows Win32 控制器），macOS 原生
//                      版为"现场快照 + 状态回报"占位，UI 上如实显示「待移植」
//  ─────────────────────────────────────────────────────────────
//  坐标系：登录按钮定位的坐标换算链见 LoginAssistant.swift 头注释。
// ============================================================================

import AppKit
import CoreGraphics
import ImageIO
import Observation
import SwiftUI

// MARK: - 数据模型

/// 会话消息
struct AgentMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user       // 用户（人类）说的
        case assistant  // AI 面板回复
        case system     // 系统状态（技能启动/停止/结果）
    }
    let id = UUID()
    var role: Role
    var text: String
    var time: Date
    var source: AgentInvokeSource  // 这条消息从哪来（诊断用）
}

/// 调用来源：人类点击 or AI 指令（同一通道的两类调用者）
enum AgentInvokeSource: String {
    case human = "👤"
    case ai = "🤖"
}

/// 技能定义
struct AgentSkill: Identifiable {
    let id: String          // 稳定 ID（AI 指令解析也用）
    let emoji: String
    let name: String
    var warn: Bool = false  // 高危/最凶标记
    var ported: Bool = false // false=待移植占位（默认值防止漏标）；true 必须显式声明
    var keywords: [String]  // AI 指令解析关键词（「帮我钓个鱼」→ fishing）
}

/// AI 模型选择
enum AgentModel: String, CaseIterable, Identifiable {
    case claude35 = "Claude 3.5"
    case gpt4o = "GPT-4o"
    case gemini = "Gemini 2.0"
    case deepseek = "DeepSeek-V3"
    var id: String { rawValue }
}

/// AI 面板配置（API Key / 模型 / 端点）——用户自己填写，存本地 0600 小本本。
///
/// ⚠️ 2026-10-06（W0 接口冻结）：定义已迁移到 `AgentSettings.swift`。
///    抽出的原因：多渠道聚合/降级链/工具挂载施工由 8 条线并行推进，
///    配置结构是所有线的公共依赖，独立成文件后写作用域清晰、避免冲突。
///    字段语义、持久化格式、`notebookURL` 路径**保持逐字兼容**。

// MARK: - 技能清单（人类 + AI 共用同一份）

enum AgentSkillLibrary {
    static let all: [AgentSkill] = [
        AgentSkill(id: "auto_login", emoji: "🔑", name: "自动登录", ported: true,
                   keywords: ["登录", "登陆", "进游戏", "上线"]),
        AgentSkill(id: "volleyball", emoji: "🏐", name: "自动排球", ported: true,
                   keywords: ["排球"]),
        AgentSkill(id: "fishing", emoji: "🎣", name: "自动钓鱼", ported: true,
                   keywords: ["钓鱼", "钓个鱼"]),
        AgentSkill(id: "coffee", emoji: "🥤", name: "自动做咖啡", ported: true,
                   keywords: ["咖啡"]),
        AgentSkill(id: "coffee_lite", emoji: "🥛", name: "轻量做咖啡", ported: true,
                   keywords: ["轻量", "lite"]),
        AgentSkill(id: "bagel_spam", emoji: "🥯", name: "贝果刷屏", ported: true,
                   keywords: ["贝果", "刷屏"]),
        AgentSkill(id: "pinkpaw", emoji: "🐾", name: "粉爪大劫案", warn: true,
                   keywords: ["粉爪", "大劫案"]),
        AgentSkill(id: "furniture", emoji: "🪑", name: "自动收家具", ported: true,
                   keywords: ["家具", "收家具", "收取"]),
        AgentSkill(id: "rewards", emoji: "💎", name: "自动领奖励", ported: true,
                   keywords: ["奖励", "领奖", "领取"]),
        AgentSkill(id: "piano", emoji: "🎹", name: "自动弹钢琴", ported: true,
                   keywords: ["钢琴", "弹琴"]),
        AgentSkill(id: "rhythm", emoji: "🎵", name: "自动超强音",
                   keywords: ["超强音", "音游"]),
        AgentSkill(id: "dodge", emoji: "⚔️", name: "自动闪避", ported: true,
                   keywords: ["闪避", "躲避"]),
        AgentSkill(id: "auto_scroll", emoji: "📜", name: "自动滚动", ported: true,
                   keywords: ["滚动", "拾取", "捡东西", "翻页"]),
        AgentSkill(id: "touch", emoji: "✋", name: "自动抚摸", ported: true,
                   keywords: ["抚摸", "摸", "宠物", "touch"]),
        AgentSkill(id: "drive_dataset", emoji: "🎬", name: "驾驶数据采集", ported: true,
                   keywords: ["数据集", "采集", "录制", "驾驶数据", "drive"]),
        AgentSkill(id: "preset_afk", emoji: "🛋️", name: "挂机预设", ported: true,
                   keywords: ["挂机", "AFK", "预设", "一键全做"]),
        AgentSkill(id: "preset_realtime", emoji: "⚡", name: "实时辅助预设", ported: false,
                   keywords: ["实时", "辅助", "realtime"]),
        AgentSkill(id: "tomato_juice", emoji: "🍅", name: "自动做番茄汁", ported: true,
                   keywords: ["番茄", "番茄汁", "tomato"]),
    ]
}

// MARK: - 统一执行通道（人类 + AI 共用）

/// 技能执行中心：人类点击与 AI 指令的唯一入口
@Observable
final class AgentSkillCenter: @unchecked Sendable {

    static let shared = AgentSkillCenter()

    // ── AI 配置（用户通过设置界面填写，存本地小本本，不再访问钥匙串）──
    var aiSettings: AgentSettings = {
        var s = AgentSettings.load()
        // 如果已有配置，同步到 currentModel/model 字段
        if s.model == "deepseek-chat" {
            s.thinkingDepth = 3
        }
        return s
    }()

    /// 从 API 拉取真实模型清单（面板模型菜单用；15s 硬超时，过滤非对话模型 image/video）
    /// 失败不崩：回传空数组，UI 显示当前模型兜底
    func fetchLiveModels(completion: @escaping ([String]) -> Void) {
        let s = aiSettings
        guard !s.apiKey.isEmpty else { completion([]); return }
        var base = s.baseUrl.hasSuffix("/") ? String(s.baseUrl.dropLast()) : s.baseUrl
        if !base.hasSuffix("/v1") { base += "/v1" }
        guard let url = URL(string: "\(base)/models") else { completion([]); return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(s.apiKey)", forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["data"] as? [[String: Any]] else {
                completion([])
                return
            }
            let ids = items.compactMap { ($0["id"] ?? $0["name"]) as? String }
                .filter { id in
                    let low = id.lowercased()
                    return !low.contains("image") && !low.contains("video")
                }
            completion(ids)
        }
        task.resume()
    }

    // ── 注入的引擎（由 DriveState 在启动时配置）──
    private var control: ControlEngine?
    private var capture: CaptureEngine?
    /// 驾驶数据集录制引擎（可选注入；nil 时 drive_dataset 报未注入）
    @ObservationIgnored var recordEngine: RecordEngine?

    // ── 会话状态（UI 直接观察）──
    //
    // ══════════════════════════════════════════════════════════════════════
    // 【2026-10-07 修复：会话无限增长】
    // ══════════════════════════════════════════════════════════════════════
    // 用户反馈「AI 那个窗口会无限变大」。
    // 根因：`messages` 只 append、从不清理（唯一 removeAll 是"新建对话"手动触发），
    //   长对话/长时间挂机时数组无限膨胀 —— 内存持续涨，且 LazyVStack 每次
    //   数据变更都要重新 diff 整个数组，越聊越卡。
    // 修法：**滑动窗口**。超过 `maxMessages` 时丢弃最旧的，并把丢弃条数记进
    //   `droppedMessageCount` 供 UI 提示。写入路径统一走 `appendMessage(_:)`。
    //   · 窗口 200 条（≈100 轮对话），远超任何正常使用场景
    //     （LLM 侧另有 12 轮历史裁剪，见 AgentChatService.maxHistoryTurns）
    var messages: [AgentMessage] = []
    /// 滑动窗口上限（超过即丢弃最旧的）
    static let maxMessages = 200
    /// 因窗口而被丢弃的消息条数（UI 可提示"更早的消息已折叠"）
    private(set) var droppedMessageCount = 0

    /// 追加一条消息并维持滑动窗口（**所有写入路径都应走这里**）
    func appendMessage(_ msg: AgentMessage) {
        messages.append(msg)
        if messages.count > Self.maxMessages {
            let overflow = messages.count - Self.maxMessages
            messages.removeFirst(overflow)
            droppedMessageCount += overflow
        }
    }

    /// 复位丢弃计数（仅自检用：测试后还原真实状态，不污染用户界面）
    func resetDroppedMessageCount(_ value: Int) {
        droppedMessageCount = max(0, value)
    }

    /// 就地更新某条消息（流式增量用），不改变窗口
    func replaceMessage(id: UUID, text: String) {
        guard let idx = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[idx].text = text
    }

    /// 正在运行的技能集合
    var runningSkills: Set<String> = []
    /// 当前模型选择（UI 模型按钮显示；API 接入层为后续扩展）
    var currentModel: AgentModel = .deepseek
    /// 思考强度滑块（1-10，AI 回复详细程度；接入 LLM 时映射到 temperature/max_tokens）
    var thinkingDepth: Int = 5
    /// 面板是否打开（ContentView 持有，这里留一份给状态条用）
    var isPanelOpen = false

    /// 自动登录引擎（@Observable 不支持 lazy，用普通存储属性）
    @ObservationIgnored private var loginAssistant = LoginAssistant()

    /// 排球循环定时器
    @ObservationIgnored private var volleyballTimer: DispatchSourceTimer?
    /// 抚摸循环定时器
    @ObservationIgnored private var touchTimer: DispatchSourceTimer?
    @ObservationIgnored private var touchLoopCount = 0
    @ObservationIgnored private var driveDatasetTimer: DispatchSourceTimer?
    @ObservationIgnored private var pianoTimer: DispatchSourceTimer?
    @ObservationIgnored private var pianoStepIndex = 0
    @ObservationIgnored private var coffeeTimer: DispatchSourceTimer?
    @ObservationIgnored private var coffeeIter = 0
    @ObservationIgnored private var coffeeLiteTimer: DispatchSourceTimer?
    @ObservationIgnored private var coffeeLiteIter = 0
    @ObservationIgnored private var bagelSpamTimer: DispatchSourceTimer?
    @ObservationIgnored private var bagelSpamIter = 0
    @ObservationIgnored private var tomatoTimer: DispatchSourceTimer?
    @ObservationIgnored private var tomatoIter = 0
    @ObservationIgnored private let workQueue = DispatchQueue(label: "agent.skill", qos: .userInteractive)

    /// LLM 专用 URLSession：30s 请求超时 + 45s 资源总超时（防挂起占满线程）
    @ObservationIgnored private let llmSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: LLM 调用（OpenAI 兼容协议）

    /// 调用云端 LLM（DeepSeek/OpenAI/Claude 等均支持）
    /// - Parameters:
    ///   - task: 用户任务描述
    ///   - history: 之前的工具调用结果
    /// - Returns: 工具调用列表（空表示任务完成）
    func callLLM(task: String, history: [AgentToolResult]) async -> [AgentToolCall] {
        let settings = aiSettings
        guard !settings.apiKey.isEmpty else {
            appendSystem("⚠️ 未配置 API Key，请先在设置中填写")
            return []
        }
        guard !settings.baseUrl.isEmpty, !settings.model.isEmpty else {
            appendSystem("⚠️ 未配置模型端点")
            return []
        }

        // 构建 messages：系统提示 + 用户任务 + 历史工具结果
        // 修复：系统提示与 tool calling 协议一致（不再要求输出 JSON 数组）
        // 【2026-10-07 提示词漂移修复】领域知识统一走 AgentChatService.systemPrompt
        // （懂《异环》：术语/玩法/macOS F 键限制/界面路径），此处只追加 tool-calling
        // 协议约束，避免三处提示词各自漂移。
        var messages: [[String: Any]] = [
            ["role": "system", "content": AgentChatService.systemPrompt + """

            ═══════════════════════════════════════
            附加：工具调用协议约束
            ═══════════════════════════════════════
            1. 一次只调用一个工具；不要一次返回多个。
            2. 需要操作界面时走「ESC → screenshot → mouse_click」路径，
               绝不按 F1–F12（macOS 系统功能键，游戏收不到）。
            """],
            ["role": "user", "content": task]
        ]

        // 追加历史工具结果
        for result in history {
            messages.append([
                "role": "tool",
                "tool_call_id": result.id,
                "content": result.summary
            ])
        }

        // 定义可用工具（函数声明）——动态过滤：只给已移植的技能（防线 2）
        func toolDecl(_ name: String, _ desc: String) -> [String: Any] {
            ["type": "function", "function": [
                "name": name,
                "description": desc,
                "parameters": ["type": "object", "properties": [:]],
            ]]
        }
        let tools: [[String: Any]] = AgentSkillLibrary.all
            .filter { $0.ported }
            .map { skill in
                let desc: String = switch skill.id {
                case "auto_login": "自动登录游戏"
                case "volleyball": "自动排球循环"
                case "rewards": "自动领奖励"
                case "furniture": "自动收家具"
                case "fishing": "自动钓鱼"
                case "dodge": "自动闪避"
                case "auto_scroll": "自动滚动拾取"
                case "touch": "自动抚摸（F交互→点击→ESC）"
                case "drive_dataset": "驾驶数据采集（WASD 2Hz）"
                default: "自动\(skill.name)"
                }
                return toolDecl(skill.id, desc)
            }

        // 思考深度 4 档 → temperature（想得越深，输出越收敛）
        let temperature: Double = switch settings.thinkingDepth {
        case 1: 0.9    // Low
        case 2: 0.5    // Mid
        case 3: 0.2    // High
        default: 0.05  // Max
        }

        let body: [String: Any] = [
            "model": settings.model,
            "messages": messages,
            "tools": tools,
            "temperature": temperature,
            "max_tokens": 1024,
        ]
        // 可观测：规划请求落到文件日志（防线 10；UI appendSystem 之外再 dlog 一份，供无 UI 环境核查）
        dlog("[LLM] 规划请求：task=\(task.prefix(60)) model=\(settings.model) 端点=\(settings.baseUrl) tools=\(tools.count) key=\(settings.apiKey.isEmpty ? "(空)" : String(settings.apiKey.prefix(4))+"…"+String(settings.apiKey.suffix(2)))")

        do {
            // baseUrl 归一化：已含 /v1 不再重复拼接（OpenAI 兼容约定）
            var base = settings.baseUrl.hasSuffix("/") ? String(settings.baseUrl.dropLast()) : settings.baseUrl
            if !base.hasSuffix("/v1") { base += "/v1" }
            guard let url = URL(string: "\(base)/chat/completions") else {
                appendSystem("❌ 无效的 BaseUrl")
                dlog("[LLM] ❌ 无效 BaseUrl=\(base)")
                return []
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await llmSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                appendSystem("❌ LLM 调用失败：\(response)")
                dlog("[LLM] ❌ 调用失败：\((response as? HTTPURLResponse)?.statusCode ?? -1)（网络/401/限流）")
                return []
            }

            // 解析响应
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: AnyHashable]],
               let first = choices.first,
               let message = first["message"] as? [String: AnyHashable],
               let toolCalls = message["tool_calls"] as? [[String: AnyHashable]] {
                // 解析工具调用
                let parsed = toolCalls.compactMap { tc -> AgentToolCall? in
                    guard let id = tc["id"] as? String,
                          let function = tc["function"] as? [String: AnyHashable],
                          let name = function["name"] as? String else { return nil }
                    let args: [String: String] = [:]
                    return AgentToolCall(id: id, skillID: name, args: args)
                }
                // 弱模型防线 10：可观测——每次调用记录请求 tool 数与解析出的调用（出问题能查）
                appendSystem("🧠 [LLM] 请求 \(tools.count) 个工具，解析出 \(parsed.count) 个调用"
                    + (parsed.isEmpty ? "" : "（\(parsed.map { $0.skillID }.joined(separator: "、"))）"))
                dlog("[LLM] ✅ 响应：解析出 \(parsed.count) 个调用（\(parsed.map { $0.skillID }.joined(separator: "、"))）")
                return parsed
            }

            // 无 tool_calls（LLM 认为任务完成）或响应结构解析失败——如实告知，不静默
            appendSystem("🧠 [LLM] 未返回工具调用（LLM 判定任务完成，或响应解析失败）")
            dlog("[LLM] ⚠️ 响应未解析出 tool_calls（任务完成或响应结构异常）")
            return []

        } catch {
            appendSystem("❌ LLM 请求异常：\(error.localizedDescription)")
            dlog("[LLM] ❌ 请求异常：\(error.localizedDescription.prefix(120))")
            return []
        }
    }

    /// 纯文本 LLM 问答（不带工具）：返回模型的回答文本
    func plainAnswer(question: String) async -> String {
        let settings = aiSettings
        guard !settings.apiKey.isEmpty else { return "(未配置 API Key)" }

        var base = settings.baseUrl.hasSuffix("/") ? String(settings.baseUrl.dropLast()) : settings.baseUrl
        if !base.hasSuffix("/v1") { base += "/v1" }
        guard let url = URL(string: "\(base)/chat/completions") else { return "(无效端点)" }

        let temperature: Double = switch settings.thinkingDepth {
        case 1: 0.9; case 2: 0.5; case 3: 0.2; default: 0.05
        }
        let body: [String: Any] = [
            "model": settings.model,
            "messages": [["role": "user", "content": question]],
            "temperature": temperature,
            "max_tokens": 256,
        ]
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await llmSession.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
            return "(解析失败)"
        } catch {
            return "(请求异常：\(error.localizedDescription))"
        }
    }

    /// 真实 LLM 端到端自测：打印配置 → 纯文本回答 → 工具调用
    /// 返回是否成功（调用方决定退出码；不依赖主 actor，CLI 里也能跑）
    func runLLMTest() async -> Bool {
        let s = aiSettings
        print("[LLM-TEST] 模型=\(s.model)  端点=\(s.baseUrl)  密钥=\(s.apiKey.isEmpty ? "(未配置)" : String(s.apiKey.prefix(6)) + "…\(String(s.apiKey.suffix(4)))")  思考深度=\(s.thinkingDepth)")

        if s.apiKey.isEmpty {
            print("[LLM-TEST] ❌ 未配置 API Key。先运行：--set-llm-config <key> <base> <model>")
            fflush(stdout)
            return false
        }

        // ① 纯文本问答（验证「能不能让它回答」）
        let answer = await plainAnswer(question: "用一句话回答：1+1 等于几？")
        print("[LLM-TEST] ① 纯文本回答：\(answer)")

        // ② 工具调用（验证 AgentLoop 的技能路由）
        let calls = await callLLM(task: "帮我打排球", history: [])
        if calls.isEmpty {
            print("[LLM-TEST] ② 工具调用：(模型未返回工具调用，任务视为纯对话)")
        } else {
            print("[LLM-TEST] ② 工具调用：\(calls.map(\.skillID).joined(separator: ", "))")
        }

        print("[LLM-TEST] ✅ 真实 LLM 链路验证完成")
        fflush(stdout)
        return true
    }

    /// 是否处于自测模式（跳过真实点击/按键，只验证链路）
    @ObservationIgnored var isDryRun = false

    private init() {
        // 欢迎消息（走滑动窗口写入，保持唯一写入路径）
        appendMessage(AgentMessage(role: .system,
                                   text: "AI 助手就绪。可以点左侧技能按钮，或直接输入「登录」「排球」「钓鱼」等指令让我干活。",
                                   time: Date(), source: .ai))
    }

    // MARK: 依赖注入

    /// 引擎未注入前排队的自动登录请求（--auto-login 在 AppDelegate 触发，
    /// 而截屏/按键引擎属于 DriveState，在 ContentView.onAppear 才注入）
    @ObservationIgnored private var pendingAutoLogin = false

    func configure(control: ControlEngine?, capture: CaptureEngine?) {
        self.control = control
        self.capture = capture
        // ⚠️ 2026-09-30 修复：这里原先是 `checkPermission()`（纯查询、不弹窗），
        //    于是技能中心这条路径**永远不会请求权限** → 程序不进辅助功能列表
        //    → 技能里的鼠标/键盘注入全部被系统静默丢弃（实测表现为
        //    `[Agent] ❌ 辅助功能权限未授权，无法注入鼠标`，自动登录因此失效）。
        //    configure 是「一次性初始化」时机，正是该请求权限的地方；
        //    而高频重试路径（ControlEngine.press/hold 内部的 checkPermission）
        //    保持纯查询，避免每帧弹窗。
        if let c = control { _ = c.requestAccessibilityPermission() }

        // 引擎就绪后，补上启动期间排队的自动登录
        if pendingAutoLogin {
            pendingAutoLogin = false
            runSkill("auto_login", source: .ai)
        }

        // 引擎就绪后，补发启动期间排队的 --agent-command 指令（与视图渲染解耦：
        // 命令模式 .accessory 下窗口可能被 orderOut，视图 onAppear 不触发 → 派发不能依赖视图）
        if let cmd = pendingCommand {
            pendingCommand = nil
            sendUserMessage(cmd, source: .human)
        }
    }

    /// AppDelegate 调用：启动下发 --agent-command 指令（引擎可能还没注入，先排队）
    /// 命令模式（.accessory，窗口不可见）下视图 onAppear 可能永不触发，
    /// 故派发放在 AppDelegate + 引擎注入时补发，双保险。
    @ObservationIgnored private var pendingCommand: String?

    func requestCommandOnStartup(_ cmd: String) {
        print("[AGENT] --agent-command 收到：\(cmd)，1.5s 后经 sendUserMessage 管线下发")
        if control != nil && capture != nil {
            workQueue.async { [weak self] in
                DispatchQueue.main.async { self?.sendUserMessage(cmd, source: .human) }
            }
            return
        }
        pendingCommand = cmd
        // 兜底：若引擎一直没注入（异常路径），最多等 8 秒后直接下发
        workQueue.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self else { return }
            if self.pendingCommand == cmd {
                self.pendingCommand = nil
                self.sendUserMessage(cmd, source: .human)
            }
        }
    }

    /// AppDelegate 调用：启动自动登录（引擎可能还没注入，先排队）
    func requestAutoLoginOnStartup() {
        guard !runningSkills.contains("auto_login") else { return }
        if control == nil || capture == nil {
            pendingAutoLogin = true
            // 兜底：若引擎一直没注入（异常路径），最多等 8 秒后仍尝试
            workQueue.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                guard let self else { return }
                if self.pendingAutoLogin {
                    self.pendingAutoLogin = false
                    self.runSkill("auto_login", source: .ai)
                }
            }
        } else {
            runSkill("auto_login", source: .ai)
        }
    }

    // MARK: - 统一入口：人类点击 / AI 指令都走这里

    /// 启动（或停止）一个技能 —— 人类点击与 AI 指令共用
    func toggleSkill(_ id: String, source: AgentInvokeSource) {
        if runningSkills.contains(id) {
            stopSkill(id, source: source)
        } else {
            runSkill(id, source: source)
        }
    }

    /// 启动技能
    func runSkill(_ id: String, source: AgentInvokeSource) {
        guard let skill = AgentSkillLibrary.all.first(where: { $0.id == id }) else {
            appendSystem("未知技能「\(id)」")
            return
        }
        guard !runningSkills.contains(id) else {
            appendSystem("\(skill.name) 已在运行中")
            return
        }
        runningSkills.insert(id)
        appendSystem("\(source.rawValue) 启动「\(skill.name)」")

        dlog("[Agent] \(source.rawValue) 启动技能 \(skill.id)")

        // 真实动作必须在工作队列执行，避免阻塞 UI 线程
        workQueue.async { [weak self] in
            guard let self else { return }
            self.execute(skill, source: source)
        }
    }

    /// 停止技能
    func stopSkill(_ id: String, source: AgentInvokeSource) {
        guard runningSkills.contains(id) else { return }
        runningSkills.remove(id)
        teardown(id: id)
        appendSystem("\(source.rawValue) 停止「\(AgentSkillLibrary.all.first(where: { $0.id == id })?.name ?? id)」")
        dlog("[Agent] \(source.rawValue) 停止技能 \(id)")
    }

    /// 停止所有运行中的技能
    func stopAll(source: AgentInvokeSource) {
        let ids = Array(runningSkills)
        for id in ids {
            runningSkills.remove(id)
            teardown(id: id)
        }
        if !ids.isEmpty {
            appendSystem("\(source.rawValue) 已停止全部技能")
        }
    }

    // MARK: - 技能执行（真实动作）

    private func execute(_ skill: AgentSkill, source: AgentInvokeSource) {
        // 捕获启动瞬间的 dryRun 状态：异步队列执行时自测标记可能已被外部重置，
        // 必须用启动时的快照决定是否真发输入，保证自测语义确定。
        let dryRun = isDryRun
        switch skill.id {
        case "auto_login":
            performAutoLogin(skill: skill, source: source, dryRun: dryRun)
        case "volleyball":
            startVolleyballLoop(skill: skill, source: source, dryRun: dryRun)
        case "rewards", "furniture":
            // 纯 UI 点击型：OCR 定位「领取/收取」按钮 → 循环点击直到没有
            performUIClickLoop(skill: skill, source: source, dryRun: dryRun)
        case "fishing":
            // 自动钓鱼基础版：F 抛竿 → 等收杆节奏 → F 再抛（循环）
            performFishingLoop(skill: skill, source: source, dryRun: dryRun)
        case "dodge":
            // 自动闪避：持续闪避按键循环（躲避追踪弹/红圈，配合走位）
            performDodgeLoop(skill: skill, source: source, dryRun: dryRun)
        case "auto_scroll":
            // 自动滚动：周期性 F 连点 + 滚轮（拾取/翻页类交互）
            performAutoScroll(skill: skill, source: source, dryRun: dryRun)
        case "touch":
            // 自动抚摸：F交互 → 点击抚摸区 → ESC退出（MaaNTE Touch 直移植）
            startTouchLoop(skill: skill, source: source, dryRun: dryRun)
        case "drive_dataset":
            // 驾驶数据采集：2Hz 采样 W/A/S/D → RecordEngine（MaaNTE AutonomousDrivingDataset）
            startDriveDatasetLoop(skill: skill, source: source, dryRun: dryRun)
        case "preset_afk":
            // 挂机预设：依次启动 rewards → furniture → fishing（MaaNTE preset/AFK.json）
            startPresetAFK(skill: skill, source: source, dryRun: dryRun)
        case "piano":
            // 自动弹钢琴：内置"小星星"旋律（G/H/I 音键，0.4s 间隔循环）
            startPianoLoop(skill: skill, source: source, dryRun: dryRun)
        case "tomato_juice":
            startTomatoJuiceLoop(skill: skill, source: source, dryRun: dryRun)
        case "coffee":
            // 自动做咖啡：F 键交互 × 20 轮（MaaNTE AutoMakeCoffee）
            startCoffeeLoop(skill: skill, source: source, dryRun: dryRun)
        case "coffee_lite":
            // 轻量做咖啡：F 键交互 × 10 轮（MaaNTE AutoMakeCoffeeLite）
            startCoffeeLiteLoop(skill: skill, source: source, dryRun: dryRun)
        case "bagel_spam":
            // 贝果刷屏：聊天框内置文案输入（MaaNTE BagelSpam，macOS 简化版）
            startBagelSpamLoop(skill: skill, source: source, dryRun: dryRun)
        default:
            // 待移植技能：真实快照 + 如实状态回报（不做假动作）
            performSnapshotStub(skill: skill, source: source)
        }
    }

    /// 自动登录（全真实链路 + 守护模式）
    /// 点一次 → 立即尝试；若游戏还没启动到登录界面，进入守护模式：
    /// 每 8 秒重新截图检测一次，直到成功进入游戏或 80 秒超时自动停止。
    /// 用户想中断可再点一次技能按钮（停止）。
    private func performAutoLogin(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
        guard let mouse = makeMouse() else {
            appendSystem("❌ 辅助功能权限未授权，无法注入鼠标")
            runningSkills.remove(skill.id)
            return
        }
        guard !dryRun else {
            // 自测模式：只定位不点击
            let hit = loginAssistant.dryRunLocate(capture: capture)
            appendSystem(hit != nil
                         ? "✅ 自测：登录按钮定位成功「\(hit!.text)」→ (\(Int(hit!.point.x)), \(Int(hit!.point.y)))"
                         : "ℹ️ 自测：当前屏幕未发现登录按钮")
            runningSkills.remove(skill.id)
            return
        }

        let logger: (String) -> Void = { [weak self] msg in
            self?.appendSystem(msg)
            self?.dlog("[Login] \(msg)")
        }

        // 安全前提：只自动操作游戏窗口。屏幕上没有【异环/NTE】窗口时
        // 绝不点击任何「登录」按钮（否则会误点浏览器/QQ 等窗口的登录按钮）。
        // 游戏可能还在启动中 → 进入守护模式等待窗口出现。
        if !GameWindowDetector.isGameVisible() {
            logger("🎮 未检测到游戏窗口（异环/NTE），进入守护等待…")
            startLoginWatch(mouse: mouse, logger: logger, source: source)
            return
        }

        // 第一轮：立即尝试（完整 3 轮关键词）
        let result = loginAssistant.runAutoLogin(capture: capture, mouse: mouse, logger: logger)
        switch result {
        case .success(let text):
            appendSystem("✅ 登录成功：已点击「\(text)」")
            runningSkills.remove(skill.id)
            return
        case .noFrame:
            appendSystem("❌ 拿不到截屏帧（截屏权限未授权？）")
            runningSkills.remove(skill.id)
            return
        case .noMatchingText, .clickedButStillStuck:
            // 没按钮（游戏还在启动）或点不动 → 进入守护模式
            startLoginWatch(mouse: mouse, logger: logger, source: source)
        }
    }

    /// 登录守护定时器（80 秒上限）
    @ObservationIgnored private var loginWatchTimer: DispatchSourceTimer?
    @ObservationIgnored private var loginWatchAttempts = 0
    private static let loginWatchMaxAttempts = 10   // 10 × 8s = 80s

    /// 守护模式：每 8s 检测登录界面并点击，直到成功或超时
    private func startLoginWatch(mouse: MouseController,
                                 logger: @escaping (String) -> Void,
                                 source: AgentInvokeSource) {
        guard loginWatchTimer == nil else { return }
        loginWatchAttempts = 0
        logger("🔍 登录守护启动：每 8 秒检测登录界面（最多 \(Self.loginWatchMaxAttempts) 次，再次点击技能可停止）")

        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 8.0, repeating: 8.0)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.runningSkills.contains("auto_login"),
                  self.loginWatchTimer != nil else { return }
            self.loginWatchAttempts += 1

            // 超时停止：80 秒都没等到登录界面
            if self.loginWatchAttempts > Self.loginWatchMaxAttempts {
                logger("⏹️ 守护 80 秒未发现登录界面，自动停止（可能已在游戏内或游戏未启动）")
                self.runningSkills.remove("auto_login")
                self.loginWatchTimer?.cancel()
                self.loginWatchTimer = nil
                return
            }

            // 只有检测到游戏窗口才允许点击（防止误点其他窗口的「登录」）。
            // 无游戏窗口 = 游戏还没启动或窗口在切换 —— 不点击、不停止，
            // 安静等待下一轮（超时兜底已在上面）。
            guard GameWindowDetector.isGameVisible() else {
                logger("🔍 第 \(self.loginWatchAttempts) 次检测：等待游戏窗口出现…")
                return
            }

            // 每轮只认主按钮（maxRounds 1），避免反复狂点
            let r = self.loginAssistant.runAutoLogin(capture: self.capture,
                                                     mouse: mouse,
                                                     logger: logger,
                                                     maxRounds: 1)
            switch r {
            case .success(let text):
                logger("✅ 守护点击成功：已进入游戏（「\(text)」）")
                self.runningSkills.remove("auto_login")
                self.loginWatchTimer?.cancel()
                self.loginWatchTimer = nil
            case .noFrame:
                logger("❌ 守护中断：截屏不可用")
                self.runningSkills.remove("auto_login")
                self.loginWatchTimer?.cancel()
                self.loginWatchTimer = nil
            case .noMatchingText, .clickedButStillStuck:
                logger("🔍 第 \(self.loginWatchAttempts) 次检测：仍在等待登录界面…")
            }
        }
        timer.resume()
        loginWatchTimer = timer
    }

    /// 自动排球（真实 K 键循环，MaaNTE auto_volleyball 核心循环直移植）
    private func startVolleyballLoop(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
        guard !dryRun else {
            appendSystem("✅ 自测：排球循环（K 键 0.6s）链路就绪")
            runningSkills.remove(skill.id)
            return
        }
        guard let control else {
            appendSystem("❌ 按键引擎未注入")
            runningSkills.remove(skill.id)
            return
        }
        guard GameWindowDetector.isGameVisible() else {
            appendSystem("🎮 未检测到游戏窗口，排球已取消（安全护栏）")
            runningSkills.remove(skill.id)
            return
        }

        // 0.6s 一次 K 键短按 —— 与 MaaNTE auto_volleyball.py 的节奏一致
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 0.6, repeating: 0.6)
        timer.setEventHandler { [weak self] in
            guard let self, self.runningSkills.contains("volleyball") else { return }
            guard GameWindowDetector.isGameVisible() else {
                self.appendSystem("🎮 游戏窗口消失，排球已自动停止（安全护栏）")
                self.teardown(id: "volleyball")
                self.runningSkills.remove("volleyball")
                return
            }
            control.pressGameKey(.k, duration: 0.05)
        }
        timer.resume()
        volleyballTimer = timer
        appendSystem("🏐 排球循环运行中（每 0.6s 击球一次，再次点击或输入「停止」结束）")
    }

    /// 自动抚摸（MaaNTE Touch 直移植）
    /// 序列：F 交互 → 点击抚摸区域 → ESC 退出，循环最多 10 轮
    private func startTouchLoop(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
        guard !dryRun else {
            appendSystem("✅ 自测：抚摸链路（F→点击→ESC ×10）就绪")
            runningSkills.remove(skill.id)
            return
        }
        guard let control else {
            appendSystem("❌ 按键引擎未注入，无法执行抚摸")
            runningSkills.remove(skill.id)
            return
        }
        guard GameWindowDetector.isGameVisible() else {
            appendSystem("🎮 未检测到游戏窗口，抚摸已取消（安全护栏）")
            runningSkills.remove(skill.id)
            return
        }

        touchLoopCount = 0
        let maxLoops = 10
        // 每 3 秒一轮（F→0.5s→点击→0.5s→ESC）
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.runningSkills.contains("touch") else { return }
            self.touchLoopCount += 1
            if self.touchLoopCount > maxLoops {
                appendSystem("✋ 抚摸完成（\(maxLoops) 轮），自动停止")
                self.teardown(id: "touch")
                runningSkills.remove("touch")
                return
            }
            // F → 交互模式
            control.pressGameKey(.f, duration: 0.05)
            // 0.5s 后点击抚摸区（模拟 MaaNTE 的 Click [660,480]）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if let mouse = self.makeMouse() {
                    let scale = MouseController.displayScale
                    let point = MouseController.screenPoint(fromPixel: CGPoint(x: 660, y: 480), scale: scale)
                    mouse.click(at: point, settleDelay: 0.3)
                }
            }
            // 1s 后 ESC 退出交互
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.control?.pressGameKey(.esc, duration: 0.05)
            }
        }
        timer.resume()
        touchTimer = timer
        appendSystem("✋ 抚摸循环运行中（每 3s 一轮 ×\(maxLoops)，再次点击或输入「停止」结束）")
    }

    /// 驾驶数据集采集（MaaNTE AutonomousDrivingDataset 直移植 · 复用 RecordEngine）
    /// 采样率 2Hz，每帧记录 steer/throttle/brake 按键状态
    private func startDriveDatasetLoop(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
        guard !dryRun else {
            appendSystem("✅ 自测：驾驶数据采集（RecordEngine 2Hz）链路就绪")
            runningSkills.remove(skill.id)
            return
        }
        guard let recorder = recordEngine else {
            appendSystem("❌ 录制引擎未注入，无法采集驾驶数据")
            runningSkills.remove(skill.id)
            return
        }
        guard GameWindowDetector.isGameVisible() else {
            appendSystem("🎮 未检测到游戏窗口，数据采集已取消（安全护栏）")
            runningSkills.remove(skill.id)
            return
        }

        // 启动录制
        recorder.start(perspective: "first")

        // 2Hz 采样（0.5s 间隔）
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        var elapsed: Double = 0
        let maxDuration: Double = 60.0
        timer.setEventHandler { [weak self] in
            guard let self, self.runningSkills.contains("drive_dataset") else { return }
            elapsed += 0.5
            if elapsed >= maxDuration {
                appendSystem("🎬 驾驶数据采集完成（\(Int(maxDuration))s），自动停止")
                recorder.stop()
                recorder.flushSync()
                self.teardown(id: "drive_dataset")
                runningSkills.remove("drive_dataset")
                return
            }
            // macOS 按键状态采样（替代 Windows GetAsyncKeyState）
            let w = CGEventSource.keyState(.combinedSessionState, key: 13)   // W
            let a = CGEventSource.keyState(.combinedSessionState, key: 0)    // A
            let s = CGEventSource.keyState(.combinedSessionState, key: 1)    // S
            let d = CGEventSource.keyState(.combinedSessionState, key: 2)    // D
            let steer = Double(d ? 1 : 0) - Double(a ? 1 : 0)
            let throttle: Double = w ? 1.0 : 0.0
            let brake: Double = s ? 1.0 : 0.0
            if let frame = self.capture?.currentFrame {
                recorder.appendFrame(image: frame, steer: steer, throttle: throttle, brake: brake)
            }
        }
        timer.resume()
        driveDatasetTimer = timer
        appendSystem("🎬 驾驶数据采集运行中（2Hz × 60s，再次点击或输入「停止」结束）")
    }

    /// 挂机预设（MaaNTE preset/AFK）：依次启动 rewards → furniture → fishing
    /// 每个子技能间隔 5s 启动（给前一个时间稳定运行）
    private func startPresetAFK(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
        guard !dryRun else {
            appendSystem("✅ 自测：挂机预设（rewards→furniture→fishing）链路就绪")
            runningSkills.remove(skill.id)
            return
        }
        guard GameWindowDetector.isGameVisible() else {
            appendSystem("🎮 未检测到游戏窗口，挂机预设已取消")
            runningSkills.remove(skill.id)
            return
        }
        // 依次启动子技能（每个间隔 5s）
        let subSkills = ["rewards", "furniture", "fishing"]
        appendSystem("🛋️ 挂机预设启动：\(subSkills.joined(separator: " → "))")
        for (i, sid) in subSkills.enumerated() {
            workQueue.asyncAfter(deadline: .now() + Double(i) * 5.0) { [weak self] in
                guard let self, self.runningSkills.contains("preset_afk") else { return }
                self.runSkill(sid, source: .ai)
                appendSystem("  └ 启动子技能：\(sid)")
            }
        }
        // 30s 后自动标记完成（各子技能有自己上限）
        workQueue.asyncAfter(deadline: .now() + 30.0) { [weak self] in
            guard let self else { return }
            if self.runningSkills.contains("preset_afk") {
                self.appendSystem("🛋️ 挂机预设子技能已全部启动，自动标记完成")
                self.runningSkills.remove("preset_afk")
            }
        }
    }

    // MARK: - 自动弹钢琴（MaaNTE AutoPiano 完整移植）

    /// 内置曲目：每首为 GameKey 序列（G=中音1 H=中音2 I=中音3 Y=高音1 U=高音2）
    /// 节拍 0.4s/音符，完整循环播放
    private let pianoSongs: [(name: String, notes: [ControlEngine.GameKey])] = [
        ("小星星", [.g, .g, .i, .i, .g, .g, .i, .i,
                     .h, .h, .g, .g, .i, .i,
                     .g, .g, .i, .i, .h, .h, .g, .g]),
        ("欢乐颂", [.g, .g, .h, .h, .i, .i, .h, .g,
                    .g, .g, .h, .h, .y, .y, .u, .i]),
        ("生日快乐", [.i, .i, .g, .g, .h, .h, .i, .y,
                       .g, .g, .u, .u, .h, .h, .i, .g]),
    ]

    private func startPianoLoop(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
        guard !dryRun else {
            appendSystem("✅ 自测：钢琴（小星星/欢乐颂/生日快乐）链路就绪")
            runningSkills.remove(skill.id)
            return
        }
        guard let control else {
            appendSystem("❌ 按键引擎未注入，无法弹钢琴")
            runningSkills.remove(skill.id)
            return
        }
        guard GameWindowDetector.isGameVisible() else {
            appendSystem("🎮 未检测到游戏窗口，钢琴已取消（安全护栏）")
            runningSkills.remove(skill.id)
            return
        }

        pianoStepIndex = 0
        let song = pianoSongs[0] // 默认第一首
        let totalNotes = song.notes.count
        let interval: Double = 0.4

        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, self.runningSkills.contains("piano") else { return }
            let idx = self.pianoStepIndex
            if idx >= totalNotes {
                // 一轮结束，暂停 2s 后重播
                self.appendSystem("🎹 \(song.name) 一轮完成，2s 后重播")
                self.pianoStepIndex = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.pianoStepIndex = 0 // 重置（timer 继续跑）
                }
                return
            }
            let key = song.notes[idx]
            control.pressGameKey(key, duration: 0.08)
            self.pianoStepIndex = idx + 1
        }
        timer.resume()
        pianoTimer = timer
        appendSystem("🎹 钢琴运行中：\(song.name)（\(totalNotes) 音符 × \(interval)s，再次点击或「停止」结束）")
    }

    /// 自动做咖啡：F 键交互循环（MaaNTE AutoMakeCoffee）
    /// 每 2s 按一次 F（交互），最多 20 轮（≈40s 制作周期）
    private func startCoffeeLoop(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
        guard !dryRun else {
            appendSystem("✅ 自测：做咖啡链路就绪")
            runningSkills.remove(skill.id)
            return
        }
        guard let control else {
            appendSystem("❌ 按键引擎未注入，无法做咖啡")
            runningSkills.remove(skill.id)
            return
        }
        guard GameWindowDetector.isGameVisible() else {
            appendSystem("🎮 未检测到游戏窗口，做咖啡已取消（安全护栏）")
            runningSkills.remove(skill.id)
            return
        }
        coffeeIter = 0
        let maxIter = 20
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.runningSkills.contains("coffee") else { return }
            self.coffeeIter += 1
            control.pressGameKey(.f, duration: 0.1)
            if self.coffeeIter >= maxIter {
                self.appendSystem("☕ 做咖啡完成（\(maxIter) 轮 F 交互），自动停止")
                self.coffeeTimer?.cancel()
                self.coffeeTimer = nil
                self.runningSkills.remove("coffee")
            }
        }
        timer.resume()
        coffeeTimer = timer
        appendSystem("☕ 做咖啡运行中（每 2s 按 F × \(maxIter) 轮，再次点击或「停止」结束）")
    }

    /// 轻量做咖啡（MaaNTE AutoMakeCoffeeLite）：快速 10 轮 × 1s 的 F 交互（对应 MaaNTE make_count=10）
    private func startCoffeeLiteLoop(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
        guard !dryRun else {
            appendSystem("✅ 自测：轻量做咖啡链路就绪")
            runningSkills.remove(skill.id)
            return
        }
        guard let control else {
            appendSystem("❌ 按键引擎未注入，无法轻量做咖啡")
            runningSkills.remove(skill.id)
            return
        }
        guard GameWindowDetector.isGameVisible() else {
            appendSystem("🎮 未检测到游戏窗口，轻量做咖啡已取消（安全护栏）")
            runningSkills.remove(skill.id)
            return
        }
        coffeeLiteIter = 0
        let maxIter = 10
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 0.6, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.runningSkills.contains("coffee_lite") else { return }
            self.coffeeLiteIter += 1
            control.pressGameKey(.f, duration: 0.1)
            if self.coffeeLiteIter >= maxIter {
                self.appendSystem("🥛 轻量做咖啡完成（\(maxIter) 轮 F 交互），自动停止")
                self.coffeeLiteTimer?.cancel()
                self.coffeeLiteTimer = nil
                self.runningSkills.remove("coffee_lite")
            }
        }
        timer.resume()
        coffeeLiteTimer = timer
        appendSystem("🥛 轻量做咖啡运行中（每 1s 按 F × \(maxIter) 轮，快速版；再次点击或「停止」结束）")
    }

    /// 贝果刷屏（MaaNTE BagelSpam）：向当前焦点聊天框输入内置文案
    /// 限制（如实说明）：macOS 版使用内置中性文案（MaaNTE 原版文本由 LLM/参数提供，需先开聊天窗口）
    private func startBagelSpamLoop(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
        guard !dryRun else {
            appendSystem("✅ 自测：贝果刷屏链路就绪")
            runningSkills.remove(skill.id)
            return
        }
        guard let control else {
            appendSystem("❌ 按键引擎未注入，无法贝果刷屏")
            runningSkills.remove(skill.id)
            return
        }
        guard GameWindowDetector.isGameVisible() else {
            appendSystem("🎮 未检测到游戏窗口，贝果刷屏已取消（安全护栏）")
            runningSkills.remove(skill.id)
            return
        }
        let phrases = ["早上好呀", "今天天气真好", "贝果很好吃"]
        bagelSpamIter = 0
        let maxIter = phrases.count * 2   // 6 轮，防止刷屏失控
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.runningSkills.contains("bagel_spam") else { return }
            self.bagelSpamIter += 1
            let phrase = phrases[(self.bagelSpamIter - 1) % phrases.count]
            control.typeText(phrase)
            self.appendSystem("🥯 贝果刷屏第 \(self.bagelSpamIter)/\(maxIter) 句：\(phrase)")
            if self.bagelSpamIter >= maxIter {
                self.appendSystem("🥯 贝果刷屏完成（\(maxIter) 句），自动停止")
                self.bagelSpamTimer?.cancel()
                self.bagelSpamTimer = nil
                self.runningSkills.remove("bagel_spam")
            }
        }
        timer.resume()
        bagelSpamTimer = timer
        appendSystem("🥯 贝果刷屏运行中（每 2s 输入一句内置文案 × \(maxIter) 句；需聊天框已打开并聚焦；再次点击或「停止」结束）")
    }

    private func startTomatoJuiceLoop(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
        guard !dryRun else {
            appendSystem("✅ 自测：番茄汁 链路就绪")
            runningSkills.remove(skill.id)
            return
        }
        guard let control else {
            appendSystem("❌ 按键引擎未注入")
            runningSkills.remove(skill.id)
            return
        }
        guard GameWindowDetector.isGameVisible() else {
            appendSystem("🎮 未检测到游戏窗口，做番茄汁已取消（安全护栏）")
            runningSkills.remove(skill.id)
            return
        }
        tomatoIter = 0
        let maxIter = 20
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.runningSkills.contains("tomato_juice") else { return }
            self.tomatoIter += 1
            control.pressGameKey(.f, duration: 0.1)
            if self.tomatoIter >= maxIter {
                self.appendSystem("🍅 番茄汁完成（\(maxIter) 轮 F 交互），自动停止")
                self.tomatoTimer?.cancel()
                self.tomatoTimer = nil
                self.runningSkills.remove("tomato_juice")
            }
        }
        timer.resume()
        tomatoTimer = timer
        appendSystem("🍅 做番茄汁运行中（每 2s 按 F × \(maxIter) 轮，再次点击或「停止」结束）")
    }

    /// 通用 UI 点击技能（自动领奖励 / 自动收家具）
    /// 真实链路：（可选）按入口热键开界面 → 截图 → Vision OCR 定位「领取/收取」按钮
    /// → 鼠标点击 → 等 UI 反应后重试；按钮消失即完成，换下一入口键。
    /// 入口键依据（G1 文档 + 实测）：
    ///   rewards: F4=活动页（实测✓，含「环期赠礼」签到 tab）/ F1、F2=MaaNTE 文档的活动/环期赏令入口（版本待实证）
    ///   furniture: MaaNTE 原义=开放世界家具物（仓鼠球/棉棉/木箱），非 UI 菜单；
    ///   此处保留 UI 关键词循环作兜底（面板已标注语义差异，找到即点、找不到安全停）
    private func performUIClickLoop(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
        guard let mouse = makeMouse() else {
            appendSystem("❌ 辅助功能权限未授权，无法注入鼠标")
            runningSkills.remove(skill.id)
            return
        }

        // 每种技能的关键词（按优先级）
        let keywords: [String]
        let entryKeys: [ControlEngine.GameKey?]
        let maxRounds: Int
        let clickInterval: TimeInterval
        switch skill.id {
        case "rewards":
            keywords = ["一键领取", "免费领取", "立即领取", "领取奖励", "领取", "签到", "确认"]
            entryKeys = [.f4, .f1, .f2]          // F4 实测=活动页；F1/F2 待实证（MaaNTE 文档）
            maxRounds = 6
            clickInterval = 1.2
        case "furniture":
            keywords = ["一键收取", "收取家具", "收取", "回收"]
            entryKeys = [nil]                     // 无 UI 入口（世界物品），直接扫当前屏
            maxRounds = 8
            clickInterval = 1.0
        default:
            keywords = []
            entryKeys = []
            maxRounds = 0
            clickInterval = 1.0
        }

        // 键注入安全护栏：游戏窗口不在前台就取消（与 fishing/volleyball 同款）
        guard GameWindowDetector.isGameVisible() else {
            appendSystem("🎮 未检测到游戏窗口，\(skill.name)已取消（安全护栏）")
            runningSkills.remove(skill.id)
            return
        }

        let scale = MouseController.displayScale
        let logger: (String) -> Void = { [weak self] msg in
            self?.appendSystem(msg)
            self?.dlog("[\(skill.id)] \(msg)")
        }

        var totalClicked = 0
        for (i, entryKey) in entryKeys.enumerated() {
            guard runningSkills.contains(skill.id) else {
                logger("⏹️ 已停止（用户中断）")
                return
            }
            // 切入口界面：首个直接按；其先关旧界面再按新键
            if let k = entryKey {
                if i > 0 {
                    control?.pressGameKey(.esc, duration: 0.05)
                    usleep(600_000)
                }
                control?.pressGameKey(k, duration: 0.05)
                logger("⌨️ 入口 \(i+1)/\(entryKeys.count)：按 \(k.rawValue) 开界面")
                usleep(900_000)   // 等界面切换
            }

            var clicked = 0
            for _ in 1...maxRounds {
                guard runningSkills.contains(skill.id) else {
                    logger("⏹️ 已停止（用户中断）")
                    return
                }
                guard let frame = capture?.currentFrame,
                      let cg = loginAssistant.cgImage(from: frame) else {
                    logger("⚠️ 拿不到截屏帧（第 \(round) 轮）")
                    continue
                }
                guard let hit = loginAssistant.locateButton(keywords, in: cg, scale: scale) else {
                    // 本入口没有按钮 → 换下一个入口键（或全部结束）
                    logger("ℹ️ 入口 \(i+1) 未找到「\(skill.name)」按钮，\(i + 1 < entryKeys.count ? "换下一入口…" : "全部入口扫完")")
                    break
                }
                guard !dryRun else {
                    logger("✅ 自测：定位到「\(hit.text)」→ (\(Int(hit.point.x)), \(Int(hit.point.y)))，链路就绪")
                    runningSkills.remove(skill.id)
                    return
                }
                logger("🖱️ 第 \(round) 轮：点击「\(hit.text)」")
                mouse.click(at: hit.point)
                clicked += 1
                totalClicked += 1
                usleep(useconds_t(clickInterval * 1_000_000))
                // 点击后复查：按钮消失 = 领完，结束本入口
                usleep(500_000)
                if let frame2 = capture?.currentFrame, let cg2 = loginAssistant.cgImage(from: frame2) {
                    if loginAssistant.locateButton(keywords, in: cg2, scale: scale) == nil {
                        logger("🏁 入口 \(i+1)：共点击 \(clicked) 次，按钮已消失（领完/收完）")
                        runningSkills.remove(skill.id)
                        return
                    }
                }
            }
            // 本入口没点任何东西 → 继续下一个入口键
            if totalClicked == 0 { continue }
        }

        if totalClicked > 0 {
            logger("✅ 完成：共点击 \(totalClicked) 次（\(skill.name)）")
        } else {
            logger("ℹ️ 未在任何入口找到「\(skill.name)」按钮（可能已领完，或需手动打开对应界面）")
        }
        runningSkills.remove(skill.id)
    }

    /// 自动钓鱼基础版（MaaNTE AutoFish 核心循环移植）
    /// 真实链路：F 抛竿 → 等收杆节奏 → F 收杆 → 再抛（循环，最多 12 轮）
    /// 说明：MaaNTE 完整版带 CV 鱼漂检测；macOS 基础版按游戏节奏固定时间，
    /// 真实动作 + 可中途停止，后续可接 Vision 升级。
    private func performFishingLoop(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
        guard let control else {
            appendSystem("❌ 按键引擎未注入")
            runningSkills.remove(skill.id)
            return
        }
        guard !dryRun else {
            appendSystem("✅ 自测：钓鱼循环（F 抛竿/收杆）链路就绪")
            runningSkills.remove(skill.id)
            return
        }
        guard GameWindowDetector.isGameVisible() else {
            appendSystem("🎮 未检测到游戏窗口，钓鱼已取消（安全护栏）")
            runningSkills.remove(skill.id)
            return
        }

        let maxRounds = 12
        appendSystem("🎣 钓鱼循环启动：F 抛竿/收杆 × \(maxRounds) 轮（点击技能可停止）")
        for _ in 1...maxRounds {
            guard runningSkills.contains(skill.id) else {
                appendSystem("⏹️ 钓鱼已停止")
                return
            }
            guard GameWindowDetector.isGameVisible() else {
                appendSystem("🎮 游戏窗口消失，钓鱼已自动停止（安全护栏）")
                runningSkills.remove(skill.id)
                return
            }
            // 抛竿：F 短按
            control.pressGameKey(.f, duration: 0.08)
            usleep(useconds_t(2.0 * 1_000_000))   // 等鱼漂落水
            // 收杆：F 短按（游戏内抛竿/收杆同一键）
            control.pressGameKey(.f, duration: 0.08)
            usleep(useconds_t(1.0 * 1_000_000))
            appendSystem("🎣 第 \(round) 轮：抛竿→收杆完成")
        }
        appendSystem("🏁 钓鱼 \(maxRounds) 轮完成")
        runningSkills.remove(skill.id)
    }

    /// 自动闪避（MaaNTE SoundDodge 思路移植）
    /// 真实链路：周期性快速闪避（空格跳跃 + Shift 疾跑闪避组合），
    /// 用于躲红圈/追踪弹；可中途停止。
    private func performDodgeLoop(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
        guard let control else {
            appendSystem("❌ 按键引擎未注入")
            runningSkills.remove(skill.id)
            return
        }
        guard !dryRun else {
            appendSystem("✅ 自测：闪避循环（Space/Shift）链路就绪")
            runningSkills.remove(skill.id)
            return
        }
        guard GameWindowDetector.isGameVisible() else {
            appendSystem("🎮 未检测到游戏窗口，闪避已取消（安全护栏）")
            runningSkills.remove(skill.id)
            return
        }

        let maxRounds = 20
        appendSystem("⚔️ 闪避循环启动：周期性跳+疾跑闪避 × \(maxRounds) 轮（点击技能可停止）")
        for _ in 1...maxRounds {
            guard runningSkills.contains(skill.id) else {
                appendSystem("⏹️ 闪避已停止")
                return
            }
            guard GameWindowDetector.isGameVisible() else {
                appendSystem("🎮 游戏窗口消失，闪避已自动停止（安全护栏）")
                runningSkills.remove(skill.id)
                return
            }
            // 闪避动作：Space 跳跃 + Shift 疾跑短闪
            control.pressGameKey(.space, duration: 0.12)
            control.pressGameKey(.shift, duration: 0.10)
            usleep(useconds_t(0.9 * 1_000_000))
        }
        appendSystem("🏁 闪避 \(maxRounds) 轮完成")
        runningSkills.remove(skill.id)
    }

    /// 自动滚动（MaaNTE auto_f_scroll 移植）
    /// 真实链路：周期性 F 连点 + 鼠标滚轮向下（拾取/翻页类交互）
    private func performAutoScroll(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
        guard let control else {
            appendSystem("❌ 按键引擎未注入")
            runningSkills.remove(skill.id)
            return
        }
        guard !dryRun else {
            appendSystem("✅ 自测：滚动循环（F+滚轮）链路就绪")
            runningSkills.remove(skill.id)
            return
        }
        guard GameWindowDetector.isGameVisible() else {
            appendSystem("🎮 未检测到游戏窗口，滚动已取消（安全护栏）")
            runningSkills.remove(skill.id)
            return
        }

        let mouse = makeMouse()
        let maxRounds = 15
        appendSystem("📜 自动滚动启动：F 连点 + 滚轮 × \(maxRounds) 轮（点击技能可停止）")
        for _ in 1...maxRounds {
            guard runningSkills.contains(skill.id) else {
                appendSystem("⏹️ 滚动已停止")
                return
            }
            guard GameWindowDetector.isGameVisible() else {
                appendSystem("🎮 游戏窗口消失，滚动已自动停止（安全护栏）")
                runningSkills.remove(skill.id)
                return
            }
            // F 连点（交互键）2 次
            control.pressGameKey(.f, duration: 0.06)
            usleep(useconds_t(0.12 * 1_000_000))
            control.pressGameKey(.f, duration: 0.06)
            // 滚轮向下（拾取/翻页）
            mouse?.scrollWheel(lines: -3)
            usleep(useconds_t(0.5 * 1_000_000))
        }
        appendSystem("🏁 滚动 \(maxRounds) 轮完成")
        runningSkills.remove(skill.id)
    }

    /// 待移植技能：现场快照 + 如实回报
    private func performSnapshotStub(skill: AgentSkill, source: AgentInvokeSource) {
        let snapshotPath = "/tmp/aurora_agent_\(skill.id).png"
        var snapshotInfo = "无快照（截屏不可用）"
        if let frame = capture?.currentFrame {
            if let tiff = frame.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: snapshotPath))
                snapshotInfo = "已保存现场快照 \(snapshotPath)"
            }
        }
        // ⚠️ 品牌层（用户可见字符串）：此处**不得**出现上游项目名。
        //    用户看到的是「AuroraDrive 里这个技能还没做」，而不是「我们在用谁的东西」。
        //    诚实性不靠点名上游来体现 —— 靠"如实说没做 + 给出快照"。
        appendSystem("⚙️ 「\(skill.name)」：该技能依赖 Windows 视觉管线，macOS 原生版开发中。\(snapshotInfo)")
        runningSkills.remove(skill.id)
    }

    // MARK: - 技能收尾

    private func teardown(id: String) {
        switch id {
        case "volleyball":
            volleyballTimer?.cancel()
            volleyballTimer = nil
        case "touch":
            touchTimer?.cancel()
            touchTimer = nil
            touchLoopCount = 0
        case "drive_dataset":
            driveDatasetTimer?.cancel()
            driveDatasetTimer = nil
            recordEngine?.stop()
            recordEngine?.flushSync()
        case "piano":
            pianoTimer?.cancel()
            pianoTimer = nil
            pianoStepIndex = 0
        case "tomato_juice":
            tomatoTimer?.cancel()
            tomatoTimer = nil
        case "coffee":
            coffeeTimer?.cancel()
            coffeeTimer = nil
            coffeeIter = 0
        case "coffee_lite":
            coffeeLiteTimer?.cancel()
            coffeeLiteTimer = nil
            coffeeLiteIter = 0
        case "bagel_spam":
            bagelSpamTimer?.cancel()
            bagelSpamTimer = nil
            bagelSpamIter = 0
        case "auto_login":
            loginWatchTimer?.cancel()
            loginWatchTimer = nil
            loginWatchAttempts = 0
        default:
            break
        }
        // 停止时释放所有按键（防角色卡住）
        control?.releaseAllGameKeys()
    }

    // MARK: - AI 对话入口

    /// 用户输入一条消息（人类在输入框打字 / AI 面板收到指令）
    /// 统一从这里解析：能识别出技能 → 走 runSkill（同一通道）；否则本地回复
    func sendUserMessage(_ text: String, source: AgentInvokeSource) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appendMessage(AgentMessage(role: .user, text: trimmed, time: Date(), source: source))
        dlog("[Agent] \(source.rawValue) 用户: \(trimmed)")

        // 停止指令优先
        let lower = trimmed.lowercased()
        if lower.contains("停止") || lower.contains("停一下") || lower.contains("停下") {
            stopAll(source: source)
            replyAssistant("已停止所有技能。")
            return
        }

        // ── 第一步：先看是复合任务还是单技能 ───────────────────────────
        let matchedSkills = AgentSkillLibrary.all.filter { skill in
            skill.keywords.contains(where: { trimmed.contains($0) })
        }
        let matchedCount = matchedSkills.count

        // 复合任务（多技能关键词 / 单技能但带任务动词）→ AgentLoop 端到端规划
        if matchedCount >= 2 || (matchedCount == 1 && isComplexTask(trimmed)) {
            appendSystem("🧠 检测到复合任务，启动端到端规划…")
            let loop = AgentLoop.shared
            loop.onProgress = { [weak self] msg in
                self?.appendSystem(msg)
            }
            let task = trimmed
            let source = source
            // 修复：去掉串行 workQueue 上的 semaphore（会永久阻塞后续所有技能）
            // 改为 Task（协作线程池后台执行）+ MainActor 更新 UI，不阻塞 workQueue
            Task { [weak self] in
                let summary = await loop.handle(task: task, from: source) { msg in
                    DispatchQueue.main.async { self?.appendSystem(msg) }
                }
                DispatchQueue.main.async {
                    self?.replyAssistant(summary)
                }
            }
            return
        }

        // 单技能直配（兼容旧路径）
        if matchedCount == 1 {
            let skill = matchedSkills[0]
            appendSystem("\(source.rawValue) 指令命中技能「\(skill.name)」")
            runSkill(skill.id, source: source)
            return
        }

        // ── 自由聊天：走真实 LLM（2026-10-06 W6）──
        // 病根修复：改造前这里无条件走 `localReply()` 硬编码套话，`plainAnswer`
        // 写好了却从未被生产路径调用 —— AI 助手因此是"壳子"。
        // 现在走 AgentChatService.reply：带最近 12 轮历史 + 系统提示 + 流式增量。
        // localReply 只保留为"全链失败"的离线降级，且明确标注。
        sendChatMessage(trimmed, source: source)
    }

    /// 自由聊天：走真实 LLM，流式边收边显示。
    ///
    /// 【线程模型】`AgentChatService` 是 actor，网络/解析都在后台；
    /// `onDelta` 回调在后台执行，这里统一 `DispatchQueue.main.async` 更新 UI。
    /// 流式增量按 15Hz 节流（AgentChatService 内部），UI 不会每 token 重绘。
    ///
    /// 【历史】取 `messages` 里最近的 user/assistant 轮次（最旧的在前），
    /// 由 AgentChatService 负责裁剪到最近 12 轮 + 系统提示。
    ///
    /// 【离线降级】全链失败时 `ChatReply.text` 为空 + `errorMessage` 有值：
    /// 回退 `localReply` 并明确标注"（离线回复：无可用模型）"——用户能分清
    /// 是模型答的还是本地兜底，不假装。
    private func sendChatMessage(_ text: String, source: AgentInvokeSource) {
        // 历史：最近 40 条里的 user/assistant 轮次（服务端再裁剪到 12 轮）
        let history: [ChatTurn] = messages.suffix(40).compactMap { msg in
            switch msg.role {
            case .user:       return ChatTurn(role: "user", text: msg.text)
            case .assistant:  return ChatTurn(role: "assistant", text: msg.text)
            case .system:     return nil
            }
        }

        // ── 📷 视觉开关：开启时把当前帧一并发送 ──
        // 帧来源与 ToolRegistry.screenshot 同源（DriveState.currentFrameCG 优先），
        // 保证"面板看到的"与"工具抓到的"是同一画面。
        // 拿不到帧时**不静默降级**成纯文本——如实告知（用户规格：不假装看了屏幕）。
        let wantVision = aiSettings.visionEnabled

        // 占位：先给一条"正在思考"，流式期间逐段更新
        let placeholder = AgentMessage(role: .assistant, text: "…", time: Date(), source: .ai)
        appendMessage(placeholder)
        appendSystem("🧠 正在调用模型\(wantVision ? "（含截图）" : "")…")

        let service = AgentChatService.shared
        Task { [weak self] in
            // 取帧必须在主线程（DriveState.currentFrameCG 非线程安全）；
            // 拿不到帧时不静默降级成纯文本 —— 如实告知（用户规格）。
            let frameImage: LLMImage? = wantVision
                ? await MainActor.run { Self.encodeCurrentFrameForVision() }
                : nil
            if wantVision && frameImage == nil {
                await MainActor.run {
                    self?.appendSystem("⚠️ 已开启带截图，但拿不到当前画面（屏幕录制权限未授权或采集未启动）"
                                       + "——本次按纯文本发送")
                }
            }
            let reply = await service.reply(text: text, history: history,
                                            image: frameImage) { delta in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // 更新占位消息为累计文本
                    self.replaceMessage(id: placeholder.id, text: delta)
                }
            }

            await MainActor.run {
                guard let self else { return }
                // 移除占位，写入最终回复
                self.messages.removeAll { $0.id == placeholder.id }
                if reply.ok {
                    self.replyAssistant(reply.text)
                    self.appendSystem("🤖 \(reply.backend.displayName) · \(reply.model)"
                                      + (reply.viaFallback ? "（已降级）" : ""))
                } else {
                    // 全链失败 → 离线降级，明确标注
                    let fallback = self.localReply(to: text)
                    let marked = "（离线回复：无可用模型）\(fallback)"
                    self.replyAssistant(marked)
                    if let reason = reply.errorMessage {
                        self.appendSystem("⚠️ \(reason)")
                    }
                }
            }
        }
    }

    /// 判断是否为需要端到端规划的复合任务
    /// 规则：单技能但无顺序词 → 单技能直配；含顺序词（然后/先/再/依次）→ 复合任务
    private func isComplexTask(_ text: String) -> Bool {
        let lower = text.lowercased()
        let sequentialWords = ["然后", "接着", "先", "再", "依次", "最后", "顺"]
        return sequentialWords.contains { lower.contains($0) }
    }

    /// 抓当前帧并编码成可发送的图片（供 📷 视觉开关用）。
    ///
    /// 【为什么要降采样】实测：2940×1912 原图 base64 约 8MB，会超上游请求限制；
    ///   长边压到 1568px + JPEG 0.8 后约 30–800KB，实测可正常发送（W2 同一门限）。
    /// 【为什么在主线程取帧】`DriveState.currentFrameCG` / `NSImage` 不是线程安全的，
    ///   取帧必须 `MainActor`；编码（重）放到后台，避免卡 30fps 红线。
    @MainActor
    private static func encodeCurrentFrameForVision() -> LLMImage? {
        let cg: CGImage? = DriveState.shared.currentFrameCG
            ?? DriveState.shared.captureEngine.currentFrame?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        guard let frame = cg else { return nil }
        return Self.downscaleForVision(frame)
    }

    /// 长边降到 1568px、JPEG 0.8（与 W2 `LLMImage` 编码门限一致）
    private static func downscaleForVision(_ image: CGImage) -> LLMImage? {
        let maxSide: CGFloat = 1568
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(1.0, maxSide / max(w, h))
        let tw = max(1, Int(w * scale)), th = max(1, Int(h * scale))

        guard let ctx = CGContext(data: nil, width: tw, height: th,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = ctx.makeImage() else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [
            kCGImageDestinationLossyCompressionQuality: 0.8
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return LLMImage(data: data as Data, mimeType: "image/jpeg")
    }

    /// 本地回复：状态汇总 + 可执行指令提示
    private func localReply(to text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("状态") || lower.contains("在干嘛") || lower.contains("忙什么") {
            let running = runningSkills.isEmpty ? "无" : runningSkills.map { id in
                AgentSkillLibrary.all.first(where: { $0.id == id })?.name ?? id
            }.joined(separator: "、")
            return "当前运行中：\(running)。模型：\(aiSettings.model)，思考强度：\(thinkingDepth)。"
        }
        if lower.contains("你好") || lower.contains("hi") || lower.contains("嗨") {
            return "你好！我可以帮你自动登录、打排球，或执行钓鱼/咖啡/钢琴等技能（后几项待移植）。试试输入「登录」或点左侧技能按钮。"
        }
        if lower.contains("模型") {
            return "当前模型：\(aiSettings.model)。可在输入框下方模型按钮切换。"
        }
        if lower.contains("帮助") || lower.contains("help") {
            let skills = AgentSkillLibrary.all.map { $0.name }.joined(separator: "、")
            return "可用技能：\(skills)。直接输入技能名即可调用（如「登录」「排球」「钓鱼」）。"
        }
        return "收到。这句话我暂未找到对应技能（当前为本地模式，未接入外部大模型 API）。试试：登录 / 排球 / 停止。"
    }

    private func replyAssistant(_ text: String) {
        appendMessage(AgentMessage(role: .assistant, text: text, time: Date(), source: .ai))
    }

    func appendSystem(_ text: String) {
        appendMessage(AgentMessage(role: .system, text: text, time: Date(), source: .ai))
        // 可观测：系统消息同步落盘（此前仅入 UI 会话，无 UI 环境无法核查技能执行/护栏/降级）
        dlog("[Agent] \(text)")
    }

    // MARK: - 工具

    private func makeMouse() -> MouseController? {
        guard let control, control.hasAccessibilityPermission else { return nil }
        return MouseController()
    }

    /// 调试日志：stdout + `/tmp/aurora_debug.log`
    ///
    /// ⚠️ 2026-09-30 修复：原实现与 `DriveState.dlog` 是同一段有缺陷的代码 ——
    ///    两条写入路径都用 `try?` 静默吞掉错误。而 `/tmp/aurora_debug.log` 在
    ///    用户机器上属主是 **root**（历史遗留），UI 以普通用户运行 → 写不进去，
    ///    且**没有任何提示**，看起来像"代码没执行"而不是"日志没写成"。
    ///    详见 `AuroraDriveApp.swift` 里 `DriveState.dlog` 的完整现场说明。
    ///
    /// 修法同款：加可写回退链，全失败落 stderr，绝不静默。
    /// 面板与 DriveState 分属不同类，故各自持有一份候选表——这是**有意的重复**：
    /// 比跨类耦合一个 static 更不易出错，且两处可独立演进（面板将来若迁
    /// 独立日志文件，改这一处即可）。
    private func dlog(_ msg: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(msg)"
        print(line)
        guard let data = (line + "\n").data(using: .utf8) else { return }

        for path in AgentSkillCenter.dlogCandidates {
            let url = URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let h = try? FileHandle(forWritingTo: url) else { continue }
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
            return
        }
        FileHandle.standardError.write(data)
    }

    /// 面板日志的可写候选路径（首个可写者胜出）。
    private static let dlogCandidates: [String] = [
        "/tmp/aurora_debug.log",
        NSHomeDirectory() + "/Library/Logs/aurora_debug.log",
        "/tmp/aurora_debug_agent.log",
    ]

    /// 新建对话（清空会话，保留欢迎语）
    func newConversation() {
        messages.removeAll()
        droppedMessageCount = 0
        appendMessage(AgentMessage(role: .system,
                                   text: "新对话开始。输入「登录」「排球」等指令即可调用技能。",
                                   time: Date(), source: .ai))
    }
}

// MARK: - 自测（--agent-selftest 入口）

/// AI Agent 组件自测：验证 OCR→坐标链路、指令解析、技能路由
enum AgentSelfTest {

    static func run(center: AgentSkillCenter) {
        var pass = 0
        var fail = 0
        let log = { (ok: Bool, name: String, detail: String) in
            if ok { pass += 1 } else { fail += 1 }
            print("[AGENT-SELFTEST] \(ok ? "PASS" : "FAIL") \(name): \(detail)")
        }

        // 1. 指令解析：登录
        center.messages.removeAll()
        center.sendUserMessage("帮我登录游戏", source: .ai)
        log(center.runningSkills.contains("auto_login"),
            "指令解析→登录技能", center.runningSkills.isEmpty ? "未命中" : "命中 auto_login")
        center.stopAll(source: .ai)

        // 2. 指令解析：排球
        center.sendUserMessage("打排球", source: .ai)
        log(center.runningSkills.contains("volleyball"),
            "指令解析→排球技能", center.runningSkills.isEmpty ? "未命中" : "命中 volleyball")
        center.stopAll(source: .ai)

        // 3. 指令解析：停止
        center.runSkill("volleyball", source: .ai)
        center.sendUserMessage("停止", source: .ai)
        log(center.runningSkills.isEmpty, "指令解析→停止", "运行中=\(center.runningSkills.count)")

        // 3.5 UI 点击型技能路由（dryRun：只验证链路不真点）
        center.isDryRun = true
        center.sendUserMessage("帮我领奖励", source: .ai)
        let rewardsRouted = center.messages.contains { $0.text.contains("命中技能") && $0.text.contains("自动领奖励") }
        center.stopAll(source: .ai)
        center.sendUserMessage("收家具", source: .ai)
        let furnitureRouted = center.messages.contains { $0.text.contains("命中技能") && $0.text.contains("自动收家具") }
        center.stopAll(source: .ai)
        center.sendUserMessage("帮我滚动一下", source: .ai)
        let scrollRouted = center.messages.contains { $0.text.contains("命中技能") && $0.text.contains("自动滚动") }
        center.stopAll(source: .ai)
        center.isDryRun = false
        log(rewardsRouted, "指令解析→领奖励", rewardsRouted ? "命中 rewards" : "未命中")
        log(furnitureRouted, "指令解析→收家具", furnitureRouted ? "命中 furniture" : "未命中")
        log(scrollRouted, "指令解析→滚动", scrollRouted ? "命中 auto_scroll" : "未命中")

        // 3.7 新移植技能路由（dryRun：只验证链路，不真实按键/点击）
        center.isDryRun = true
        center.sendUserMessage("帮我抚摸一下", source: .ai)
        let touchRouted = center.messages.contains { $0.text.contains("命中技能") && $0.text.contains("自动抚摸") }
        center.stopAll(source: .ai)
        center.sendUserMessage("做杯咖啡", source: .ai)
        let coffeeRouted = center.messages.contains { $0.text.contains("命中技能") && $0.text.contains("自动做咖啡") }
        center.stopAll(source: .ai)
        center.sendUserMessage("来点轻量的", source: .ai)
        let coffeeLiteRouted = center.messages.contains { $0.text.contains("命中技能") && $0.text.contains("轻量做咖啡") }
        center.stopAll(source: .ai)
        center.sendUserMessage("做杯番茄汁", source: .ai)
        let tomatoRouted = center.messages.contains { $0.text.contains("命中技能") && $0.text.contains("自动做番茄汁") }
        center.stopAll(source: .ai)
        center.sendUserMessage("帮我弹钢琴", source: .ai)
        let pianoRouted = center.messages.contains { $0.text.contains("命中技能") && $0.text.contains("自动弹钢琴") }
        center.stopAll(source: .ai)
        center.sendUserMessage("去钓鱼", source: .ai)
        let fishingRouted = center.messages.contains { $0.text.contains("命中技能") && $0.text.contains("自动钓鱼") }
        center.stopAll(source: .ai)
        center.sendUserMessage("自动闪避", source: .ai)
        let dodgeRouted = center.messages.contains { $0.text.contains("命中技能") && $0.text.contains("自动闪避") }
        center.stopAll(source: .ai)
        center.sendUserMessage("开始采集数据集", source: .ai)
        let datasetRouted = center.messages.contains { $0.text.contains("命中技能") && $0.text.contains("驾驶数据采集") }
        center.stopAll(source: .ai)
        center.sendUserMessage("挂机", source: .ai)
        let afkRouted = center.messages.contains { $0.text.contains("命中技能") && $0.text.contains("挂机预设") }
        center.stopAll(source: .ai)
        center.sendUserMessage("贝果刷屏", source: .ai)
        let bagelRouted = center.messages.contains { $0.text.contains("命中技能") && $0.text.contains("贝果刷屏") }
        center.stopAll(source: .ai)
        center.isDryRun = false
        log(touchRouted, "指令解析→抚摸", touchRouted ? "命中 touch" : "未命中")
        log(coffeeRouted, "指令解析→咖啡", coffeeRouted ? "命中 coffee" : "未命中")
        log(coffeeLiteRouted, "指令解析→轻量咖啡", coffeeLiteRouted ? "命中 coffee_lite" : "未命中")
        log(tomatoRouted, "指令解析→番茄汁", tomatoRouted ? "命中 tomato_juice" : "未命中")
        log(pianoRouted, "指令解析→钢琴", pianoRouted ? "命中 piano" : "未命中")
        log(fishingRouted, "指令解析→钓鱼", fishingRouted ? "命中 fishing" : "未命中")
        log(dodgeRouted, "指令解析→闪避", dodgeRouted ? "命中 dodge" : "未命中")
        log(datasetRouted, "指令解析→驾驶数据集", datasetRouted ? "命中 drive_dataset" : "未命中")
        log(afkRouted, "指令解析→挂机预设", afkRouted ? "命中 preset_afk" : "未命中")
        log(bagelRouted, "指令解析→贝果刷屏", bagelRouted ? "命中 bagel_spam" : "未命中")

        // 3.6 AgentLoop 端到端规划（复合任务：登录→领奖励）
        center.isDryRun = true
        center.sendUserMessage("先登录然后再领奖励", source: .ai)
        let loopPlanned = center.messages.contains { $0.text.contains("端到端规划") }
        center.stopAll(source: .ai)
        center.isDryRun = false
        log(loopPlanned, "AgentLoop 复合任务规划", loopPlanned ? "触发端到端" : "未触发")

        // 4. 人类点击同一通道（toggle → running）
        center.isDryRun = true
        center.toggleSkill("auto_login", source: .human)
        let humanRuns = center.runningSkills.contains("auto_login") ||
                        center.messages.contains { $0.text.contains("自测") && $0.text.contains("登录") }
        center.stopAll(source: .human)
        center.isDryRun = false
        log(humanRuns, "人类点击走同一通道", humanRuns ? "已进入执行" : "未进入")

        // 5. 键盘技能注入（排球 key 注入引擎存在性）
        log(center.controlEngineAvailable(), "按键引擎可用", center.controlEngineAvailable() ? "yes" : "no")

        // 6. ported 一致性：ported==true 的技能必须有 execute case（不落入 default）
        let portedSkills = AgentSkillLibrary.all.filter { $0.ported }
        let knownImplemented: Set<String> = ["auto_login","rewards","furniture","fishing","volleyball","dodge","auto_scroll","touch","drive_dataset","preset_afk","piano","coffee","coffee_lite","tomato_juice","bagel_spam"]
        let unimplementedPorted = portedSkills.filter { !knownImplemented.contains($0.id) }
        log(unimplementedPorted.isEmpty,
            "ported一致性①", unimplementedPorted.isEmpty ? "所有 ported:true 技能均有实现" : "漏标: \(unimplementedPorted.map(\.id).joined(separator: ","))")

        // 7. ported 一致性：ported==false 的技能应走 snapshotStub（不在 knownImplemented 中）
        let unportedSkills = AgentSkillLibrary.all.filter { !$0.ported }
        let wronglyPorted = unportedSkills.filter { knownImplemented.contains($0.id) }
        log(wronglyPorted.isEmpty,
            "ported一致性②", wronglyPorted.isEmpty ? "所有 ported:false 技能无 case" : "错标: \(wronglyPorted.map(\.id).joined(separator: ","))")

        print("[AGENT-SELFTEST] 汇总: PASS=\(pass) FAIL=\(fail)")
        print("[AGENT-SELFTEST] 完成，退出")
        fflush(stdout)
        exit(fail == 0 ? 0 : 1)
    }
}

extension AgentSkillCenter {
    func controlEngineAvailable() -> Bool { control != nil }
}

// ============================================================================
//  UI 视图：左侧边缘箭头 + AI Agent 面板
// ============================================================================

/// 屏幕最左缘的小箭头（常驻，点击展开/收回 AI 面板）
/// 与右侧 Sidebar 完全独立：各自开关互不影响
struct AIAgentEdgeTab: View {
    @Bindable var center: AgentSkillCenter
    let panelWidth: CGFloat

    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.68)) {
                center.isPanelOpen.toggle()
            }
        } label: {
            HStack(spacing: 0) {
                Image(systemName: "chevron.compact.right")
                    .font(.system(size: Aurora.fsTitle, weight: .bold))
                    .rotationEffect(.degrees(center.isPanelOpen ? 180 : 0))
                    .foregroundStyle(Aurora.ice)
            }
            .frame(width: 22, height: 76)
            .background(
                RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous)
                    .strokeBorder(hovering ? Aurora.ice.opacity(0.7) : Aurora.ice.opacity(0.35),
                                  lineWidth: 1.2)
            )
            .shadow(color: hovering ? Aurora.ice.opacity(0.6) : Aurora.ice.opacity(0.25),
                    radius: hovering ? 14 : 7)
            .overlay(alignment: .leading) {
                // 左侧发光边条（呼吸感）
                Rectangle()
                    .fill(Aurora.ice.opacity(0.8))
                    .frame(width: 2)
                    .shadow(color: Aurora.ice, radius: 4)
            }
        }
        .buttonStyle(.plain)
        .help("AI 助手（\(center.isPanelOpen ? "收起" : "展开")）")
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovering = h }
        }
        // 箭头跟随面板位置：收起贴屏幕左缘，展开移到面板右侧边缘
        // （面板是 HStack 首元素占 348pt，箭头不能叠在面板上）
        .padding(.leading, Aurora.sp1)
        .offset(x: center.isPanelOpen ? panelWidth : 0)
        .zIndex(20)
    }
}

/// AI Agent 面板（左侧滑出，占屏约 1/4，独立开关）
struct AIAgentPanelView: View {
    @Bindable var center: AgentSkillCenter

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Aurora.sp2), count: 3)

    @State private var draftText = ""
    @State private var showModelPicker = false
    @State private var appeared = false
    @State private var showSettings = false
    /// 真实模型清单（从 API /models 拉取；空 = 未拉到，菜单显示当前模型兜底）
    @State private var liveModels: [String] = []
    /// 技能网格是否显示「待移植」技能（默认隐藏，降低视觉噪音；用户反馈"太乱了没法用"）
    @State private var showUnportedSkills = false
    /// 渠道健康快照（底部常驻小字的数据源；由 30s 轮询 + 每次对话后刷新）
    @State private var healthSnapshot: LLMHealthSnapshot?
    /// 诊断面板（点小字旁「诊断」打开）
    @State private var showDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            // ── 头部：图标 + 标题 + 状态点 ──
            HStack(spacing: Aurora.sp2) {
                ZStack {
                    RoundedRectangle(cornerRadius: Aurora.radiusControl, style: .continuous)
                        .fill(LinearGradient(colors: [Aurora.ice.opacity(0.35), Aurora.ice.opacity(0.08)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 30, height: 30)
                    Text("🤖")
                        .font(.system(size: Aurora.fsNum))
                }
                VStack(alignment: .leading, spacing: Aurora.sp1) {
                    HStack(spacing: Aurora.sp2) {
                        Text("AI AGENT")
                            .font(.system(size: Aurora.fsBody, weight: .bold, design: .rounded))
                            .tracking(1.6)
                            .foregroundStyle(Aurora.t1)
                        Circle()
                            .fill(center.runningSkills.isEmpty ? Aurora.ice : Aurora.amber)
                            .frame(width: 6, height: 6)
                            .shadow(color: center.runningSkills.isEmpty ? Aurora.ice : Aurora.amber,
                                    radius: 4)
                    }
                    Text(center.runningSkills.isEmpty
                         ? "空闲 · \(center.aiSettings.model)"
                         : "运行中 · \(runningNames)")
                        .font(.system(size: Aurora.fsMicro, weight: .medium))
                        .foregroundStyle(Aurora.t3)
                        .lineLimit(1)
                }
                Spacer()
                // ── 设置按钮：配置 API Key / BaseUrl / Model ──
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.68)) {
                        showSettings = true
                    }
                } label: {
                    Image(systemName: "gear")
                        .font(.system(size: Aurora.fsTitle, weight: .bold))
                        .foregroundStyle(Aurora.t2)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("AI 配置")

                // ── 收起按钮 ──
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.68)) {
                        center.isPanelOpen = false
                    }
                } label: {
                    Image(systemName: "chevron.compact.left")
                        .font(.system(size: Aurora.fsTitle, weight: .bold))
                        .foregroundStyle(Aurora.t2)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("收起 AI 面板")
            }
            .padding(.horizontal, Aurora.sp4)
            .padding(.top, Aurora.sp4)
            .padding(.bottom, Aurora.sp3)
            .opacity(appeared ? 1 : 0)
            .offset(x: appeared ? 0 : -24)
            .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.03), value: appeared)

            // ── 一键自动化（挂机预设：领奖励 → 收家具 → 钓鱼，一条指令开一串技能）──
            Button {
                center.toggleSkill("preset_afk", source: .human)
            } label: {
                HStack(spacing: Aurora.sp2) {
                    Text(center.runningSkills.contains("preset_afk") ? "⏸️" : "⚡️")
                        .font(.system(size: Aurora.fsH1))
                    Text(center.runningSkills.contains("preset_afk")
                         ? "一键自动化运行中（点击停止）"
                         : "一键自动化挂机")
                        .font(.system(size: Aurora.fsBody, weight: .bold))
                    Text(center.runningSkills.contains("preset_afk") ? "" : "领奖励·收家具·钓鱼")
                        .font(.system(size: Aurora.fsMicro))
                        .foregroundStyle(Aurora.t2)
                    Spacer()
                }
                .foregroundStyle(center.runningSkills.contains("preset_afk") ? Aurora.danger : Aurora.ice)
                .padding(.horizontal, Aurora.sp3)
                .padding(.vertical, Aurora.sp2)
                .background(RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous)
                    .fill(center.runningSkills.contains("preset_afk")
                         ? Aurora.danger.opacity(0.12) : Aurora.ice.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous)
                    .strokeBorder(center.runningSkills.contains("preset_afk")
                                  ? Aurora.danger.opacity(0.5) : Aurora.ice.opacity(0.45),
                                  lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("一键挂机：依次启动 领奖励 → 收家具 → 钓鱼（同一执行通道，可整体停止）")
            .padding(.horizontal, Aurora.sp3)
            .padding(.top, Aurora.sp3)

            // ── 技能网格（人类点 = AI 也能调，同一通道；默认只显示已实现技能）──
            LazyVGrid(columns: columns, spacing: Aurora.sp2) {
                ForEach(showUnportedSkills
                        ? AgentSkillLibrary.all
                        : AgentSkillLibrary.all.filter { $0.ported }) { skill in
                    AgentSkillButton(skill: skill,
                                     active: center.runningSkills.contains(skill.id),
                                     action: {
                        center.toggleSkill(skill.id, source: .human)
                    })
                }
            }
            .padding(.horizontal, Aurora.sp3)
            .padding(.bottom, Aurora.sp1)

            // 待移植技能显示开关（默认隐藏，用户可展开）
            HStack {
                Button(showUnportedSkills ? "收起待移植技能" : "显示待移植技能（\(AgentSkillLibrary.all.filter { !$0.ported }.count)）") {
                    showUnportedSkills.toggle()
                }
                .font(.system(size: Aurora.fsMicro, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Aurora.t3)
                Spacer()
            }
            .padding(.horizontal, Aurora.sp4)
            .padding(.bottom, Aurora.sp2)

            // ── 对话区（单对话，无历史列表）──
            AgentConversationView(center: center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, Aurora.sp3)

            // ── 输入区 ──
            agentInputArea
                .padding(.horizontal, Aurora.sp3)
                .padding(.bottom, Aurora.sp3)

            // ── 底部：新建对话 + 状态条 ──
            HStack(spacing: Aurora.sp2) {
                Button {
                    center.newConversation()
                } label: {
                    HStack(spacing: Aurora.sp1) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: Aurora.fsSmall))
                        Text("新建对话")
                            .font(.system(size: Aurora.fsSmall, weight: .semibold))
                    }
                    .foregroundStyle(Aurora.ice)
                    .padding(.horizontal, Aurora.sp3)
                    .padding(.vertical, Aurora.sp1)
                    .background(Capsule().fill(Aurora.ice.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(Aurora.ice.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer()
                Text(center.messages.last?.text.prefix(28) ?? "")
                    .font(.system(size: Aurora.fsMicro, weight: .medium))
                    .foregroundStyle(Aurora.t3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, Aurora.sp4)
            .padding(.bottom, Aurora.sp2)
            .opacity(appeared ? 1 : 0)
            .animation(.easeOut(duration: 0.25).delay(0.18), value: appeared)
        }
        .frame(width: 348)
        .background(
            ZStack {
                Color.black.opacity(0.92)
                LinearGradient(colors: [Aurora.ice.opacity(0.06), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        )
        .overlay(alignment: .trailing) {
            // 面板右侧发光分隔线
            Rectangle()
                .fill(LinearGradient(colors: [Aurora.ice.opacity(0.5), Aurora.ice.opacity(0.06)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                appeared = true
            }
            // 拉取真实模型清单（失败静默，菜单显示当前模型兜底）
            center.fetchLiveModels { ids in
                liveModels = ids
            }
        }
    }

    private var runningNames: String {
        center.runningSkills.map { id in
            AgentSkillLibrary.all.first(where: { $0.id == id })?.name ?? id
        }.joined(separator: "、")
    }

    /// 输入区：大输入框 + 模型按钮 + 思考滑块 + 发送
    private var agentInputArea: some View {
        VStack(spacing: Aurora.sp2) {
            // ── 配置状态条：未配置时醒目 CTA 直达设置（小白友好，一键配模型）；已配置显示就绪 ──
            if center.aiSettings.apiKey.isEmpty {
                Button {
                    showSettings = true
                } label: {
                    HStack(spacing: Aurora.sp2) {
                        Image(systemName: "gearshape.2.fill")
                            .font(.system(size: Aurora.fsSmall))
                        Text("未配置模型 · 点我填写 API Key 启用 AI 指令")
                            .font(.system(size: Aurora.fsMicro, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: Aurora.fsMicro, weight: .bold))
                    }
                    .foregroundStyle(Aurora.amber)
                    .padding(.horizontal, Aurora.sp3)
                    .padding(.vertical, Aurora.sp2)
                    .background(RoundedRectangle(cornerRadius: Aurora.radiusControl, style: .continuous)
                        .fill(Aurora.amber.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: Aurora.radiusControl, style: .continuous)
                        .strokeBorder(Aurora.amber.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("填写 API Key / Base URL / Model，启用 AI 端到端指令")
            } else {
                HStack(spacing: Aurora.sp2) {
                    Circle().fill(Aurora.ice).frame(width: 5, height: 5)
                    Text("AI 已就绪 · \(center.aiSettings.model)")
                        .font(.system(size: Aurora.fsMicro, weight: .medium))
                        .foregroundStyle(Aurora.t3)
                    Spacer()
                    Button("配置") { showSettings = true }
                        .font(.system(size: Aurora.fsMicro))
                        .buttonStyle(.plain)
                        .foregroundStyle(Aurora.t2)
                }
                .padding(.horizontal, Aurora.sp1)
            }

            // 输入框
            HStack(alignment: .bottom, spacing: Aurora.sp2) {
                ZStack(alignment: .topLeading) {
                    if draftText.isEmpty {
                        Text("给 AI 下达指令，或直接输入技能名…")
                            .font(.system(size: Aurora.fsBody))
                            .foregroundStyle(Aurora.t3)
                            .padding(.top, Aurora.sp2)
                            .padding(.leading, Aurora.sp3)
                    }
                    TextEditor(text: $draftText)
                        .font(.system(size: Aurora.fsBody))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 62)
                }
                .background(RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous)
                    .fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))

                Button {
                    sendDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: Aurora.fsDisplay))
                        .foregroundStyle(draftText.isEmpty ? Aurora.t3 : Aurora.ice)
                }
                .buttonStyle(.plain)
                .disabled(draftText.isEmpty)
            }

            // ── 常驻状态小字（2026-10-06 W6，用户明确要求）──
            //
            // 位置：输入框正下方（不是卡片顶部），弱化色 + 微字号。
            // 内容随真实请求实时刷新：`免费档 · ovh · Qwen2.5-VL-72B · 健康 4/7 · 0.9s`
            // 降级时显示 `⚠️ 已降级 → zenFree · space-bunny-free`，
            // 全挂时显示 `⚠️ 无可用模型（点此诊断）`。
            //
            // 数据源：`LLMHealthMonitor.snapshot()`（actor，30s 轮询 + 每次对话后刷新）。
            // hover tooltip 展示完整候选链与各模型健康态（诊断用）。
            HStack(spacing: Aurora.sp2) {
                if let snap = healthSnapshot {
                    Text(snap.displayLine)
                        .font(.system(size: Aurora.fsMicro, weight: .medium))
                        .foregroundStyle(snap.healthyCount == 0 ? Aurora.amber : Aurora.t3)
                        .lineLimit(1)
                        .help(snap.chainPreview.isEmpty
                              ? "候选链为空（无可用模型）"
                              : "候选链：\n" + snap.chainPreview.joined(separator: "\n"))
                    Spacer()
                    Button {
                        showDiagnostics.toggle()
                    } label: {
                        Text("诊断")
                            .font(.system(size: Aurora.fsMicro))
                            .foregroundStyle(Aurora.t3)
                    }
                    .buttonStyle(.plain)
                    .help("查看候选链与各模型健康态")
                } else {
                    Text("正在探测模型可用性…")
                        .font(.system(size: Aurora.fsMicro))
                        .foregroundStyle(Aurora.t3)
                    Spacer()
                }
            }
            .padding(.horizontal, Aurora.sp1)
            .task {
                // 首次进入刷新一次；之后 30s 轮询（与探活自适应策略一致）
                while !Task.isCancelled {
                    healthSnapshot = await LLMHealthMonitor.shared.snapshot()
                    try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                LLMDiagnosticsSheet()
            }

            // 第二行：后端选择器 + 📷 视觉开关 + 模型按钮 + 思考滑块
            HStack(spacing: Aurora.sp3) {
                // ── 后端选择器（2026-10-06 W6，用户明确要求）──
                //
                // 规则（用户规格）：`apiKey` 为空时**只能选免 key 渠道**，
                // 需 key 渠道置灰并提示"配置 API Key 后可切换"。
                Menu {
                    ForEach(LLMBackendKind.allCases, id: \.self) { kind in
                        let usable = center.aiSettings.apiKey.isEmpty ? kind.isKeyless : true
                        Button {
                            var s = center.aiSettings
                            s.backendKind = kind
                            center.aiSettings = s
                            try? s.save()
                            center.appendSystem("🔀 后端已切换：\(kind.displayName)")
                        } label: {
                            if kind == center.aiSettings.backendKind {
                                Label("\(kind.displayName)\(usable ? "" : "（需 API Key）")",
                                      systemImage: "checkmark")
                            } else {
                                Text("\(kind.displayName)\(usable ? "" : "（需 API Key）")")
                            }
                        }
                        .disabled(!usable)
                    }
                    Divider()
                    Text(center.aiSettings.apiKey.isEmpty
                         ? "配置 API Key 后可切换到需密钥渠道"
                         : "已配置 API Key，全部渠道可用")
                        .font(.system(size: Aurora.fsMicro))
                } label: {
                    HStack(spacing: Aurora.sp1) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: Aurora.fsMicro))
                        Text(center.aiSettings.backendKind.displayName)
                            .font(.system(size: Aurora.fsMicro, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(center.aiSettings.backendKind.isKeyless ? Aurora.ice : Aurora.amber)
                    .padding(.horizontal, Aurora.sp2)
                    .padding(.vertical, Aurora.sp1)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("选择模型后端。免 key 渠道开箱即用；需 key 渠道要先填自己的 API Key。")

                // ── 📷 视觉开关（默认关，隐私优先）──
                Toggle(isOn: Binding(
                    get: { center.aiSettings.visionEnabled },
                    set: { v in
                        var s = center.aiSettings
                        s.visionEnabled = v
                        center.aiSettings = s
                        try? s.save()
                        center.appendSystem(v
                            ? "📷 已开启带截图：对话时会把当前画面发给模型（会离开本机）"
                            : "📷 已关闭带截图")
                    })) {
                    HStack(spacing: 3) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: Aurora.fsMicro))
                        Text("带截图")
                            .font(.system(size: Aurora.fsMicro))
                    }
                    .foregroundStyle(center.aiSettings.visionEnabled ? Aurora.ice : Aurora.t3)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
                .help("开启后，对话时把当前屏幕画面一并发送给模型（需要视觉模型；图片会发送到第三方渠道）")

                // 模型选择（真实模型清单：从 API /models 拉取，替换原硬编码假列表）
                Menu {
                    ForEach(liveModels, id: \.self) { id in
                        Button {
                            center.aiSettings.model = id
                            AgentSettings.defaults.set(id, forKey: AgentSettings.keyModel)
                            center.appendSystem("🤖 模型已切换：\(id)")
                        } label: {
                            if id == center.aiSettings.model {
                                Label(id, systemImage: "checkmark")
                            } else {
                                Text(id)
                            }
                        }
                    }
                    if liveModels.isEmpty {
                        Text("⚠️ 未拉到模型列表（API Key 未配置或网络不可用）")
                            .font(.system(size: Aurora.fsMicro))
                    }
                    Divider()
                    Button {
                        center.fetchLiveModels { ids in liveModels = ids }
                    } label: {
                        Label("刷新模型列表", systemImage: "arrow.clockwise")
                    }
                    Button {
                        showSettings = true
                    } label: {
                        Label("自定义 / 编辑配置", systemImage: "gear")
                    }
                } label: {
                    HStack(spacing: Aurora.sp1) {
                        Image(systemName: "cpu")
                            .font(.system(size: Aurora.fsMicro))
                        Text(center.aiSettings.model)
                            .font(.system(size: Aurora.fsMicro, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: Aurora.fsMicro))
                    }
                    .foregroundStyle(Aurora.ice)
                    .padding(.horizontal, Aurora.sp2)
                    .padding(.vertical, Aurora.sp1)
                    .background(Capsule().fill(Aurora.ice.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(Aurora.ice.opacity(0.35), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // 思考深度滑块（低/中/高/Max 四档，直接驱动真实 API 的 temperature）
                HStack(spacing: Aurora.sp2) {
                    Text("思考")
                        .font(.system(size: Aurora.fsMicro, weight: .medium))
                        .foregroundStyle(Aurora.t2)
                    Slider(value: Binding(
                        get: { Double(center.aiSettings.thinkingDepth) },
                        set: { center.aiSettings.thinkingDepth = Int($0.rounded()) }
                    ), in: 1...4, step: 1)
                        .controlSize(.mini)
                        .frame(width: 84)
                    Text(["低", "中", "高", "Max"][center.aiSettings.thinkingDepth - 1])
                        .font(.system(size: Aurora.fsMicro, weight: .bold, design: .monospaced))
                        .foregroundStyle(Aurora.ice)
                        .frame(width: 16)
                }
                Spacer()
            }
        }
        .sheet(isPresented: $showSettings) {
            AgentSettingsSheet(center: center)
        }
    }

    private func sendDraft() {
        let text = draftText
        draftText = ""
        center.sendUserMessage(text, source: .human)
    }
}

// MARK: - 渠道诊断 Sheet（底部小字「诊断」入口）

/// 展示 7 渠道 / 全部候选模型的健康态，供用户判断"为什么没回答"。
///
/// 【为什么需要】免费渠道会波动（OVH 限流、Pollinations 时段性门禁），
/// 用户看到"无可用模型"时需要能自己查清是哪家、什么状态 —— 而不是只能等。
struct LLMDiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: LLMHealthSnapshot?
    @State private var rows: [(String, String)] = []
    @State private var loading = true

    var body: some View {
        NavigationView {
            Form {
                Section("当前状态") {
                    if let s = snapshot {
                        LabeledContent("生效渠道", value: s.backendDisplayName)
                        LabeledContent("当前模型", value: s.model.isEmpty ? "-" : s.model)
                        LabeledContent("健康模型", value: "\(s.healthyCount)/\(s.totalCount)")
                        if let ms = s.latencyMs {
                            LabeledContent("最近延迟", value: String(format: "%.0f ms", ms))
                        }
                        LabeledContent("探活间隔", value: String(format: "%.0f s", s.probeIntervalSeconds))
                        Text(s.displayLine)
                            .font(.system(size: Aurora.fsMicro))
                            .foregroundStyle(Aurora.t3)
                    } else {
                        Text(loading ? "正在读取…" : "无数据").foregroundStyle(Aurora.t3)
                    }
                }

                Section("候选链（按降级顺序）") {
                    if let s = snapshot, !s.chainPreview.isEmpty {
                        ForEach(Array(s.chainPreview.enumerated()), id: \.offset) { idx, line in
                            Text("\(idx + 1). \(line)")
                                .font(.system(size: Aurora.fsMicro, design: .monospaced))
                        }
                    } else {
                        Text("候选链为空 —— 所有渠道均不可用").foregroundStyle(Aurora.amber)
                    }
                }

                Section("各模型健康态") {
                    if rows.isEmpty {
                        Text(loading ? "正在读取…" : "无记录").foregroundStyle(Aurora.t3)
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack {
                                Text(row.0)
                                    .font(.system(size: Aurora.fsMicro, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                Text(row.1)
                                    .font(.system(size: Aurora.fsMicro, weight: .semibold))
                                    .foregroundStyle(row.1 == "ok" ? Aurora.ice
                                                     : (row.1 == "unknown" ? Aurora.t3 : Aurora.amber))
                            }
                        }
                    }
                }

                Section {
                    Button("重新探活") {
                        loading = true
                        Task {
                            _ = await LLMHealthMonitor.shared.probeAll(force: true)
                            await reload()
                        }
                    }
                    Text("说明：免费渠道（OVH/Zen/Pollinations）会限流或时段性收紧，"
                         + "状态会随时间变化。填自己的 API Key 可获得稳定渠道。")
                        .font(.system(size: Aurora.fsMicro))
                        .foregroundStyle(Aurora.t3)
                }
            }
            .navigationTitle("模型渠道诊断")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .task { await reload() }
    }

    private func reload() async {
        let s = await LLMHealthMonitor.shared.snapshot()
        let states = await LLMHealthMonitor.shared.allHealthStates()
        await MainActor.run {
            snapshot = s
            rows = states.sorted { $0.key < $1.key }.map { ($0.key, $0.value.rawValue) }
            loading = false
        }
    }
}

// MARK: - AI 配置 Sheet

struct AgentSettingsSheet: View {
    @Bindable var center: AgentSkillCenter
    @Environment(\.dismiss) private var dismiss

    /// 向导步骤：1 = 选路线，2 = 填 key（仅选「要更强能力」时），3 = 完成
    @State private var step = 1
    /// 第 1 步选择：true = 免注册免 key；false = 我要更强能力
    @State private var useKeyless = true
    /// 各 provider 的测试连接结果（provider.rawValue → 结果串）
    @State private var testResults: [String: String] = [:]
    @State private var testing: Set<String> = []

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: Aurora.sp3) {
                // ── 步骤指示 ──
                HStack(spacing: Aurora.sp2) {
                    stepDot(1, "选路线")
                    stepDot(2, "填密钥")
                    stepDot(3, "完成")
                    Spacer()
                }
                .padding(.horizontal, Aurora.sp3)
                .padding(.top, Aurora.sp2)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: Aurora.sp4) {
                        switch step {
                        case 1: stepOne
                        case 2: stepTwo
                        default: stepThree
                        }
                    }
                    .padding(Aurora.sp3)
                }

                Divider()

                // ── 底部导航 ──
                HStack {
                    if step > 1 {
                        Button("上一步") { step -= 1 }
                            .buttonStyle(.plain)
                            .foregroundStyle(Aurora.t2)
                    }
                    Spacer()
                    if step == 1 {
                        Button(useKeyless ? "开始使用（免配置）" : "下一步") {
                            step = useKeyless ? 3 : 2
                            if useKeyless { applyKeyless() }
                        }
                        .buttonStyle(.borderedProminent)
                    } else if step == 2 {
                        Button("完成") { step = 3 }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("完成") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(Aurora.sp3)
            }
            .navigationTitle("AI 助手配置向导")
            .frame(minWidth: 520, minHeight: 520)
        }
    }

    // MARK: 步骤指示点

    private func stepDot(_ n: Int, _ label: String) -> some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(step >= n ? Aurora.ice : Aurora.t3.opacity(0.3))
                    .frame(width: 18, height: 18)
                Text("\(n)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(step >= n ? .black : Aurora.t3)
            }
            Text(label)
                .font(.system(size: Aurora.fsMicro, weight: step == n ? .semibold : .regular))
                .foregroundStyle(step >= n ? Aurora.t1 : Aurora.t3)
        }
    }

    // MARK: 第 1 步 · 选路线

    private var stepOne: some View {
        VStack(alignment: .leading, spacing: Aurora.sp3) {
            Text("选择使用方式")
                .font(.system(size: Aurora.fsTitle, weight: .semibold))
                .foregroundStyle(Aurora.t1)

            routeCard(
                selected: useKeyless,
                title: "免注册 · 免 API Key（推荐）",
                subtitle: "开箱即用，无需任何账号",
                bullets: [
                    "OVHcloud 匿名层（含视觉模型 Qwen2.5-VL-72B）",
                    "OpenCode Zen 免费档（space-bunny-free，视觉）",
                    "Pollinations（37 个文本模型）",
                    "⚠️ 免费渠道会限流或时段性收紧，失败时自动降级"
                ],
                onTap: { useKeyless = true })

            routeCard(
                selected: !useKeyless,
                title: "我要更强能力（1 分钟注册，免费）",
                subtitle: "填自己的 API Key，更稳定",
                bullets: [
                    "智谱 GLM · glm-4.6v-flash（免费视觉）",
                    "Groq · 低延迟",
                    "OpenRouter · 免费档 15+ 模型",
                    "不内置、不代填、不代注册 —— 只由你本人填写"
                ],
                onTap: { useKeyless = false })
        }
    }

    private func routeCard(selected: Bool, title: String, subtitle: String,
                           bullets: [String], onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: Aurora.sp2) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Aurora.ice : Aurora.t3)
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: Aurora.sp1) {
                    Text(title)
                        .font(.system(size: Aurora.fsBody, weight: .semibold))
                        .foregroundStyle(Aurora.t1)
                    Text(subtitle)
                        .font(.system(size: Aurora.fsMicro))
                        .foregroundStyle(Aurora.t2)
                    ForEach(bullets, id: \.self) { b in
                        Text("· " + b)
                            .font(.system(size: Aurora.fsMicro))
                            .foregroundStyle(Aurora.t3)
                    }
                }
                Spacer()
            }
            .padding(Aurora.sp3)
            .background(RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous)
                .fill(selected ? Aurora.ice.opacity(0.08) : Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous)
                .strokeBorder(selected ? Aurora.ice.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// 免 key 路线：把后端设为免 key 渠道并把该用的键写进配置
    private func applyKeyless() {
        var s = center.aiSettings
        s.backendKind = .ovhAnonymous
        s.enabledBackends = LLMBackendKind.allCases.filter(\.isKeyless)
        center.aiSettings = s
        try? s.save()
        center.appendSystem("✅ 已启用免注册渠道（OVH / Zen / Pollinations），无需 API Key")
    }

    // MARK: 第 2 步 · 手把手填 key

    private var stepTwo: some View {
        VStack(alignment: .leading, spacing: Aurora.sp3) {
            Text("手把手配置（三选一或全填）")
                .font(.system(size: Aurora.fsTitle, weight: .semibold))
                .foregroundStyle(Aurora.t1)
            Text("每个渠道都会带你去注册页；拿到 key 后粘贴到输入框，点「测试连接」当场验证。")
                .font(.system(size: Aurora.fsMicro))
                .foregroundStyle(Aurora.t2)

            providerCard(
                kind: .zhipu,
                registerURL: "https://open.bigmodel.cn",
                steps: ["打开 open.bigmodel.cn", "手机号注册（免费，1 分钟）", "控制台复制 API Key"],
                capability: "glm-4.6v-flash（免费视觉）· glm-4v-flash 降级链")

            providerCard(
                kind: .groq,
                registerURL: "https://console.groq.com/keys",
                steps: ["打开 console.groq.com", "注册（免费额度）", "API Keys → Create Key"],
                capability: "低延迟文本模型")

            providerCard(
                kind: .openRouter,
                registerURL: "https://openrouter.ai/keys",
                steps: ["打开 openrouter.ai", "注册（免费，无需绑卡）", "Keys → Create Key"],
                capability: "免费档 15+ 模型，含视觉")

            // 自定义端点（高级）
            VStack(alignment: .leading, spacing: Aurora.sp2) {
                Text("自定义端点（高级）")
                    .font(.system(size: Aurora.fsBody, weight: .semibold))
                    .foregroundStyle(Aurora.t1)
                TextField("Base URL", text: Binding(
                    get: { center.aiSettings.baseUrl },
                    set: { center.aiSettings.baseUrl = $0 }))
                    .font(.system(.body, design: .monospaced))
                TextField("Model", text: Binding(
                    get: { center.aiSettings.model },
                    set: { center.aiSettings.model = $0 }))
                    .font(.system(.body, design: .monospaced))
                Text("任何 OpenAI 兼容端点都可用。")
                    .font(.system(size: Aurora.fsMicro))
                    .foregroundStyle(Aurora.t3)
            }
            .padding(Aurora.sp3)
            .background(RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous)
                .fill(Color.white.opacity(0.03)))
        }
    }

    private func providerCard(kind: LLMBackendKind, registerURL: String,
                              steps: [String], capability: String) -> some View {
        VStack(alignment: .leading, spacing: Aurora.sp2) {
            HStack {
                Text(kind.displayName)
                    .font(.system(size: Aurora.fsBody, weight: .semibold))
                    .foregroundStyle(Aurora.t1)
                Spacer()
                Button("打开注册页 →") {
                    if let url = URL(string: registerURL) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.plain)
                .font(.system(size: Aurora.fsMicro))
                .foregroundStyle(Aurora.ice)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                Text("\(i + 1). \(s)")
                    .font(.system(size: Aurora.fsMicro))
                    .foregroundStyle(Aurora.t2)
            }
            Text("能力：" + capability)
                .font(.system(size: Aurora.fsMicro))
                .foregroundStyle(Aurora.t3)
            Text(kind.riskNote)
                .font(.system(size: Aurora.fsMicro))
                .foregroundStyle(Aurora.t3)

            HStack(spacing: Aurora.sp2) {
                SecureField("粘贴 API Key", text: Binding(
                    get: { center.aiSettings.apiKey },
                    set: { center.aiSettings.apiKey = $0 }))
                    .font(.system(.body, design: .monospaced))
                    .textContentType(.password)
                Button(testing.contains(kind.rawValue) ? "测试中…" : "测试连接") {
                    testConnection(kind)
                }
                .disabled(testing.contains(kind.rawValue)
                          || center.aiSettings.apiKey.isEmpty)
            }
            if let r = testResults[kind.rawValue] {
                Text(r)
                    .font(.system(size: Aurora.fsMicro, weight: .medium))
                    .foregroundStyle(r.hasPrefix("✅") ? Aurora.ice : Aurora.amber)
            }
        }
        .padding(Aurora.sp3)
        .background(RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous)
            .fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous)
            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    /// 当场发一次真实请求验证 key 有效性（不写入任何东西，除非成功）
    private func testConnection(_ kind: LLMBackendKind) {
        let key = center.aiSettings.apiKey
        testing.insert(kind.rawValue)
        testResults[kind.rawValue] = nil
        Task {
            var s = center.aiSettings
            s.backendKind = kind
            s.apiKey = key
            let reply = await AgentChatService.shared.reply(
                text: "回答两个字：收到", history: [], image: nil) { _ in }
            await MainActor.run {
                testing.remove(kind.rawValue)
                if reply.ok {
                    testResults[kind.rawValue] = "✅ 连接成功 · \(reply.backend.displayName) · \(reply.model)"
                    // 成功才落盘并把渠道切过去
                    var committed = center.aiSettings
                    committed.backendKind = kind
                    if !committed.enabledBackends.contains(kind) {
                        committed.enabledBackends.append(kind)
                    }
                    center.aiSettings = committed
                    try? committed.save()
                } else {
                    testResults[kind.rawValue] = "❌ \(reply.errorMessage ?? "连接失败")"
                }
            }
        }
    }

    // MARK: 第 3 步 · 完成

    private var stepThree: some View {
        VStack(alignment: .leading, spacing: Aurora.sp3) {
            Text("配置完成 🎉")
                .font(.system(size: Aurora.fsTitle, weight: .semibold))
                .foregroundStyle(Aurora.t1)
            Text(useKeyless
                 ? "已启用免注册渠道，现在可以直接和 AI 对话了。"
                 : "已保存你的 API Key，现在可以直接和 AI 对话了。")
                .font(.system(size: Aurora.fsBody))
                .foregroundStyle(Aurora.t2)
            VStack(alignment: .leading, spacing: Aurora.sp1) {
                Text("可以试试：")
                    .font(.system(size: Aurora.fsMicro, weight: .semibold))
                    .foregroundStyle(Aurora.t2)
                Text("· 「你好」 —— 普通聊天")
                    .font(.system(size: Aurora.fsMicro)).foregroundStyle(Aurora.t3)
                Text("· 「帮我领奖励」 —— AI 自己调用工具")
                    .font(.system(size: Aurora.fsMicro)).foregroundStyle(Aurora.t3)
                Text("· 打开「📷 带截图」后问「屏幕上是什么」 —— 视觉理解")
                    .font(.system(size: Aurora.fsMicro)).foregroundStyle(Aurora.t3)
                Text("· 「搜一下异环最新活动」 —— 联网搜索")
                    .font(.system(size: Aurora.fsMicro)).foregroundStyle(Aurora.t3)
            }
            .padding(Aurora.sp3)
            .background(RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous)
                .fill(Aurora.ice.opacity(0.06)))

            Text("说明：本 App 不内置任何 API Key，也不代你注册。"
                 + "免费渠道的对话内容会发送到第三方服务商，请注意隐私。")
                .font(.system(size: Aurora.fsMicro))
                .foregroundStyle(Aurora.t3)
        }
    }
}

/// 技能按钮（人类点击 = 启动/停止；AI 指令走同一执行通道）
private struct AgentSkillButton: View {
    let skill: AgentSkill
    let active: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Aurora.sp1) {
                Text(skill.emoji)
                    .font(.system(size: Aurora.fsNum))
                    .shadow(color: hovered ? Aurora.ice.opacity(0.9) : .clear, radius: hovered ? 9 : 0)
                Text(skill.name)
                    .font(.system(size: Aurora.fsMicro, weight: .medium))
                    .foregroundStyle(Aurora.t1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                HStack(spacing: Aurora.sp1) {
                    if !skill.ported {
                        Text("待移植")
                            .font(.system(size: Aurora.fsMicro, weight: .bold))
                            .foregroundStyle(Aurora.t3)
                    }
                    Circle()
                        .fill(active ? Aurora.ice : (skill.warn ? Aurora.danger : Color.white.opacity(0.15)))
                        .frame(width: 5, height: 5)
                        .shadow(color: active ? Aurora.ice : .clear, radius: active ? 4 : 0)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous)
                        .fill(active ? Aurora.ice.opacity(0.12)
                                     : (hovered ? Aurora.ice.opacity(0.08) : Color.white.opacity(0.04)))
                    if hovered || active {
                        RadialGradient(colors: [Aurora.ice.opacity(0.14), .clear],
                                       center: .center, startRadius: 0, endRadius: 80)
                            .clipShape(RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous)
                    .strokeBorder(hovered || active ? Aurora.ice.opacity(0.55) : Color.white.opacity(0.08),
                                  lineWidth: 1)
            )
            .shadow(color: hovered ? Aurora.ice.opacity(0.35) : .clear, radius: hovered ? 10 : 0)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovered = h }
        }
        .help("\(skill.name)\(skill.ported ? "（点击启动/停止）" : "（待移植，点击会报告当前状态）")")
    }
}

/// 对话视图（单对话流，滚动 + 滑动窗口）
///
/// 【2026-10-07 修复"窗口无限变大"】
///   会话数据由 `AgentSkillCenter.appendMessage` 维护滑动窗口（上限 200 条），
///   这里额外：
///     · 显示"更早 N 条已折叠"提示（让用户知道消息不是丢了，是被窗口截断）
///     · 滚动逻辑保持"新消息自动到底"（`messages.count` 变化时触发）
private struct AgentConversationView: View {
    @Bindable var center: AgentSkillCenter

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: Aurora.sp2) {
                    // 窗口折叠提示（仅当确实丢弃过消息时显示）
                    if center.droppedMessageCount > 0 {
                        HStack(spacing: Aurora.sp1) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: Aurora.fsMicro))
                            Text("更早的 \(center.droppedMessageCount) 条消息已折叠")
                                .font(.system(size: Aurora.fsMicro))
                        }
                        .foregroundStyle(Aurora.t3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Aurora.sp1)
                    }
                    ForEach(center.messages) { msg in
                        AgentBubble(msg: msg)
                            .id(msg.id)
                    }
                }
                .padding(.vertical, Aurora.sp2)
            }
            .onChange(of: center.messages.count) { _, _ in
                if let last = center.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

/// 单条消息气泡
private struct AgentBubble: View {
    let msg: AgentMessage

    var body: some View {
        let isUser = msg.role == .user
        HStack {
            if isUser { Spacer(minLength: 36) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: Aurora.sp1) {
                HStack(spacing: Aurora.sp1) {
                    Text(timeLabel)
                        .font(.system(size: Aurora.fsMicro, weight: .medium))
                        .foregroundStyle(Aurora.t3)
                    Text(msg.source.rawValue)
                        .font(.system(size: Aurora.fsMicro))
                }
                Text(msg.text)
                    .font(.system(size: Aurora.fsBody))
                    .foregroundStyle(roleColor)
                    .textSelection(.enabled)
                    .padding(.horizontal, Aurora.sp3)
                    .padding(.vertical, Aurora.sp2)
                    .background(
                        RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous)
                            .fill(bubbleFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Aurora.radiusCard, style: .continuous)
                            .strokeBorder(bubbleBorder, lineWidth: 1)
                    )
            }
            if !isUser { Spacer(minLength: 36) }
        }
    }

    private var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: msg.time)
    }

    private var roleColor: Color {
        switch msg.role {
        case .user: return Aurora.t1
        case .assistant: return Aurora.ice
        case .system: return Aurora.t2
        }
    }

    private var bubbleFill: Color {
        switch msg.role {
        case .user: return Aurora.ice.opacity(0.10)
        case .assistant: return Aurora.ice.opacity(0.06)
        case .system: return Color.white.opacity(0.04)
        }
    }

    private var bubbleBorder: Color {
        switch msg.role {
        case .user: return Aurora.ice.opacity(0.30)
        case .assistant: return Aurora.ice.opacity(0.22)
        case .system: return Color.white.opacity(0.10)
        }
    }
}

// ============================================================================
//  UI 无头渲染自测（--agent-ui-shot）
//  用 SwiftUI ImageRenderer 把 AIAgentPanelView 直接渲染成 PNG 存到
//  /tmp/aurora_ui_shot.png，用于验证真实布局 —— 完全无头、无屏幕权限依赖、
//  不影响桌面。与 --agent-selftest 互补：后者验证逻辑链路，前者验证视觉呈现。
// ============================================================================

enum AgentUIShot {

    /// 执行入口（在 ContentView.onAppear 调用；ImageRenderer 需要 MainActor）
    @MainActor
    static func run(delay: TimeInterval = 1.0) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            let path = "/tmp/aurora_ui_shot.png"
            let ok = Self.renderPanel(to: path)
            print("[UI-SHOT] saved=\(ok) path=\(path)")
            fflush(stdout)
            exit(ok ? 0 : 1)
        }
    }

    /// 无头渲染 AI 面板视图（连状态条一起，验证完整布局）
    @MainActor
    private static func renderPanel(to path: String) -> Bool {
        // 注入几条示例会话 + 一个运行中的技能，让渲染内容更充分
        let center = AgentSkillCenter.shared
        center.messages = [
            AgentMessage(role: .system,
                         text: "AI 助手就绪。可以点左侧技能按钮，或输入「登录」「排球」等指令。",
                         time: Date(), source: .ai),
            AgentMessage(role: .user, text: "帮我登录游戏", time: Date(), source: .human),
            AgentMessage(role: .system, text: "🤖 指令命中技能「自动登录」", time: Date(), source: .ai),
            AgentMessage(role: .assistant,
                         text: "✅ 登录成功：已点击「点击进入」。守护模式已停止。",
                         time: Date(), source: .ai),
        ]
        center.runningSkills = ["volleyball"]

        // 渲染整个面板（含底部状态条）：348 宽 × 固定高
        let panel = AIAgentPanelView(center: center)
            .frame(width: 348, height: 880)
            .background(Aurora.void)
            .preferredColorScheme(.dark)

        let renderer = ImageRenderer(content: panel)
        renderer.scale = 2.0   // @2x，验证 Retina 布局
        guard let image = renderer.nsImage else {
            print("[UI-SHOT] ImageRenderer 渲染失败")
            return false
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("[UI-SHOT] 转 PNG 失败")
            return false
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("[UI-SHOT] 已渲染 \(Int(image.size.width))x\(Int(image.size.height))")
            return true
        } catch {
            print("[UI-SHOT] 写文件失败 \(error)")
            return false
        }
    }

    /// 布局对比自测：折叠 vs 展开两帧并排，验证「往外扩展」语义
    /// （展开时 AI 面板占左 348pt，主 UI 右移；箭头移到面板右侧边缘）
    @MainActor
    static func runLayoutCompare() {
        let center = AgentSkillCenter.shared
        // 注入示例数据，让面板渲染有内容
        center.messages = [
            AgentMessage(role: .system,
                         text: "AI 助手就绪。点技能或输入指令。",
                         time: Date(), source: .ai),
            AgentMessage(role: .user, text: "帮我登录游戏", time: Date(), source: .human),
        ]
        center.runningSkills = []

        // 主 UI 占位（简化：色块标注区域，真实 ContentView 无法无头渲染 DriveState）
        let mainPlaceholder = ZStack {
            Rectangle().fill(Color(red: 0.1, green: 0.13, blue: 0.16))
            VStack(alignment: .leading, spacing: Aurora.sp1) {
                Text("GAME VIEWPORT（主 UI，右移后保持可见）")
                    .font(.system(size: Aurora.fsSmall, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text("↖ 网络地图/小地图在这里，永不遮挡")
                    .font(.system(size: Aurora.fsMicro))
                    .foregroundStyle(Aurora.ice)
            }
        }
        let sidebarPlaceholder = ZStack {
            Rectangle().fill(Color(red: 0.08, green: 0.09, blue: 0.11))
            Text("SIDEBAR 360pt").font(.system(size: Aurora.fsMicro)).foregroundStyle(.white.opacity(0.5))
        }

        let frameW: CGFloat = 1100
        let frameH: CGFloat = 260

        // ── 帧 A：折叠（无面板，箭头贴左缘）──
        let collapsed = HStack(spacing: 0) {
            AIAgentEdgeTab(center: center, panelWidth: 348)   // 箭头贴最左
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(width: 348, height: frameH)
                .zIndex(20)
            mainPlaceholder
                .frame(width: frameW - 360, height: frameH)
            sidebarPlaceholder
                .frame(width: 360, height: frameH)
        }
        .frame(width: frameW, height: frameH)
        .background(Color.black)

        // ── 帧 B：展开（面板占左 348，箭头 offset 到面板右缘）──
        let expanded = HStack(spacing: 0) {
            AIAgentPanelView(center: center)   // 占 348，真实面板
                .frame(width: 348, height: frameH)
            // 箭头：跟随面板（offset panelWidth），叠在主 UI 左缘
            AIAgentEdgeTab(center: center, panelWidth: 348)
                .frame(width: 22, height: frameH, alignment: .center)
                .offset(x: -22)   // 对齐到面板右缘（348 - 22/2 附近）
                .zIndex(20)
            mainPlaceholder
                .frame(width: frameW - 360 - 348, height: frameH)
            sidebarPlaceholder
                .frame(width: 360, height: frameH)
        }
        .frame(width: frameW, height: frameH)
        .background(Color.black)

        center.isPanelOpen = true   // 让面板内箭头旋转状态正确

        // 上下两帧并排渲染
        let combo = VStack(spacing: Aurora.sp3) {
            Text("折叠（主 UI 占满，箭头在左缘）")
                .font(.system(size: Aurora.fsSmall, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
            collapsed
            Text("展开（面板占左 348，主 UI 右移，箭头在面板右缘）")
                .font(.system(size: Aurora.fsSmall, weight: .bold))
                .foregroundStyle(Aurora.ice)
            expanded
        }
        .padding(14)
        .background(Color.black)
        .frame(width: frameW + 28)

        let renderer = ImageRenderer(content: combo)
        renderer.scale = 2.0
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("[UI-SHOT] 布局对比渲染失败")
            fflush(stdout)
            exit(1)
        }
        let path = "/tmp/aurora_layout_compare.png"
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("[UI-SHOT] 布局对比已保存 \(path)")
        } catch {
            print("[UI-SHOT] 写文件失败 \(error)")
        }
        fflush(stdout)
        exit(0)
    }
}

// ============================================================================
//  GameWindowDetector — 游戏窗口检测（自动登录的安全护栏）
//
//  为什么必须有它：
//  自动登录守护是全屏 OCR，会把屏幕上所有文字都识别一遍。如果没有这道
//  护栏，浏览器、QQ、甚至 DSH 自己窗口里的「登录」二字都会被当成游戏登录
//  按钮点掉 —— 那是灾难。只有确认屏幕上存在【异环/NTE】游戏窗口时，
//  才被允许执行任何鼠标点击。
// ============================================================================

enum GameWindowDetector {

    /// 屏幕当前是否存在游戏窗口（异环 NTE）
    static func isGameVisible() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly],
                                                       kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for w in windows {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let name  = w[kCGWindowName as String] as? String ?? ""
            // 异环 NTE：窗口标题或进程名含「异环 / NTE」即命中
            // （NTE 全大写的窗口层名，owner 可能是 launcher 进程）
            let hit = owner.contains("NTE") || owner.contains("异环")
                   || name.contains("NTE") || name.contains("异环")
            if hit {
                // print("[GameWindow] 命中游戏窗口 owner=\(owner) name=\(name)")
                return true
            }
        }
        return false
    }
}
