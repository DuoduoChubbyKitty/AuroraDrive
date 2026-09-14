// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

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
    var ported: Bool = true // true=原生已实现（真实动作）；false=待移植占位
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

/// AI 面板配置（API Key / 模型 / 端点）——用户自己填写，安全存 Keychain
struct AgentSettings: Codable, Sendable {
    var apiKey: String = ""
    var baseUrl: String = "https://api.deepseek.com"
    var model: String = "deepseek-chat"
    var thinkingDepth: Int = 1  // 1-5，对应不同模型参数

    static let service = "com.aurora.drive.aiagent"
    static let keyApi = "apiKey"
    static let keyBase = "baseUrl"
    static let keyModel = "model"
    static let keyDepth = "thinkingDepth"

    /// 保存到 Keychain（安全存储，不写磁盘明文）
    func save() throws {
        guard !apiKey.isEmpty else { return }
        let encoder = JSONEncoder()
        try? SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AgentSettings.service,
        ] as NSDictionary)
        let params: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AgentSettings.service,
            kSecAttrAccount as String: AgentSettings.keyApi,
            kSecValueData as String: apiKey.data(using: .utf8) ?? Data(),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemAdd(params as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try? SecItemUpdate([kSecAttrAccount as String: AgentSettings.keyApi] as NSDictionary,
                               [kSecValueData as String: apiKey.data(using: .utf8) ?? Data()] as NSDictionary)
        }
        // 非敏感字段存 UserDefaults（Keychain 只存 key）
        UserDefaults.standard.set(baseUrl, forKey: AgentSettings.keyBase)
        UserDefaults.standard.set(model, forKey: AgentSettings.keyModel)
        UserDefaults.standard.set(thinkingDepth, forKey: AgentSettings.keyDepth)
    }

    /// 从 Keychain 加载
    static func load() -> AgentSettings {
        var settings = AgentSettings()
        // 读取 apiKey
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyApi,
            kSecReturnData as String: true,
            kSecMatchLimit as String: 1,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data {
            settings.apiKey = String(data: data, encoding: .utf8) ?? ""
        }
        // 读取非敏感字段
        settings.baseUrl = UserDefaults.standard.string(forKey: keyBase) ?? settings.baseUrl
        settings.model = UserDefaults.standard.string(forKey: keyModel) ?? settings.model
        settings.thinkingDepth = UserDefaults.standard.integer(forKey: keyDepth)
        return settings
    }

    /// 删除 Keychain 中的 API Key
    static func deleteKeychain() {
        try? SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyApi,
        ] as NSDictionary)
    }
}

// MARK: - 技能清单（人类 + AI 共用同一份）

enum AgentSkillLibrary {
    static let all: [AgentSkill] = [
        AgentSkill(id: "auto_login", emoji: "🔑", name: "自动登录", ported: true,
                   keywords: ["登录", "登陆", "进游戏", "上线"]),
        AgentSkill(id: "volleyball", emoji: "🏐", name: "自动排球", ported: true,
                   keywords: ["排球"]),
        AgentSkill(id: "fishing", emoji: "🎣", name: "自动钓鱼", ported: true,
                   keywords: ["钓鱼", "钓个鱼"]),
        AgentSkill(id: "coffee", emoji: "🥤", name: "自动做咖啡",
                   keywords: ["咖啡"]),
        AgentSkill(id: "pinkpaw", emoji: "🐾", name: "粉爪大劫案", warn: true,
                   keywords: ["粉爪", "大劫案"]),
        AgentSkill(id: "furniture", emoji: "🪑", name: "自动收家具", ported: true,
                   keywords: ["家具", "收家具", "收取"]),
        AgentSkill(id: "rewards", emoji: "💎", name: "自动领奖励", ported: true,
                   keywords: ["奖励", "领奖", "领取"]),
        AgentSkill(id: "piano", emoji: "🎹", name: "自动弹钢琴",
                   keywords: ["钢琴", "弹琴"]),
        AgentSkill(id: "rhythm", emoji: "🎵", name: "自动超强音",
                   keywords: ["超强音", "音游"]),
        AgentSkill(id: "dodge", emoji: "⚔️", name: "自动闪避", ported: true,
                   keywords: ["闪避", "躲避"]),
        AgentSkill(id: "auto_scroll", emoji: "📜", name: "自动滚动", ported: true,
                   keywords: ["滚动", "拾取", "捡东西", "翻页"]),
    ]
}

// MARK: - 统一执行通道（人类 + AI 共用）

/// 技能执行中心：人类点击与 AI 指令的唯一入口
@Observable
final class AgentSkillCenter: @unchecked Sendable {

    static let shared = AgentSkillCenter()

    // ── AI 配置（用户通过设置界面填写，存 Keychain）──
    var aiSettings: AgentSettings = {
        var s = AgentSettings.load()
        // 如果已有配置，同步到 currentModel/model 字段
        if s.model == "deepseek-chat" {
            s.thinkingDepth = 3
        }
        return s
    }()

    // ── 注入的引擎（由 DriveState 在启动时配置）──
    private var control: ControlEngine?
    private var capture: CaptureEngine?

    // ── 会话状态（UI 直接观察）──
    var messages: [AgentMessage] = []
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
    @ObservationIgnored private let workQueue = DispatchQueue(label: "agent.skill", qos: .userInteractive)

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
        var messages: [[String: Any]] = [
            ["role": "system", "content": """
            你是异环游戏的自动化助手。你可以调用以下技能完成任务：
            - auto_login: 自动登录游戏
            - volleyball: 自动排球（每0.6秒按K）
            - rewards: 自动领奖励（OCR定位按钮点击）
            - furniture: 自动收家具（OCR定位按钮点击）
            - fishing: 自动钓鱼（F抛竿/收杆循环）
            - dodge: 自动闪避（Space+Shift组合）
            - auto_scroll: 自动滚动拾取（F连点+滚轮）
            
            返回 JSON 数组，每个元素包含 skillID 和 args。
            只返回技能 ID，不要多余解释。
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

        // 定义可用工具（函数声明）
        let tools: [[String: Any]] = [
            ["type": "function", "function": ["name": "auto_login", "description": "自动登录游戏"]],
            ["type": "function", "function": ["name": "volleyball", "description": "自动排球循环"]],
            ["type": "function", "function": ["name": "rewards", "description": "自动领奖励"]],
            ["type": "function", "function": ["name": "furniture", "description": "自动收家具"]],
            ["type": "function", "function": ["name": "fishing", "description": "自动钓鱼"]],
            ["type": "function", "function": ["name": "dodge", "description": "自动闪避"]],
            ["type": "function", "function": ["name": "auto_scroll", "description": "自动滚动拾取"]],
        ]

        let body: [String: Any] = [
            "model": settings.model,
            "messages": messages,
            "tools": tools,
            "temperature": Double(settings.thinkingDepth) / 5.0,  // 1-5 → 0.2-1.0
            "max_tokens": 1024,
        ]

        do {
            guard let url = URL(string: "\(settings.baseUrl)/v1/chat/completions") else {
                appendSystem("❌ 无效的 BaseUrl")
                return []
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                appendSystem("❌ LLM 调用失败：\(response)")
                return []
            }

            // 解析响应
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: AnyHashable]],
               let first = choices.first,
               let message = first["message"] as? [String: AnyHashable],
               let toolCalls = message["tool_calls"] as? [[String: AnyHashable]] {
                // 解析工具调用
                return toolCalls.compactMap { tc in
                    guard let id = tc["id"] as? String,
                          let function = tc["function"] as? [String: AnyHashable],
                          let name = function["name"] as? String else { return nil }
                    let args: [String: String] = [:]
                    return AgentToolCall(id: id, skillID: name, args: args)
                }
            }

            // 无 tool_calls，返回空（LLM 认为任务完成）
            return []

        } catch {
            appendSystem("❌ LLM 请求异常：\(error.localizedDescription)")
            return []
        }
    }

    /// 是否处于自测模式（跳过真实点击/按键，只验证链路）
    @ObservationIgnored var isDryRun = false

    private init() {
        // 欢迎消息
        messages.append(AgentMessage(role: .system,
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
        if let c = control { _ = c.checkPermission() }

        // 引擎就绪后，补上启动期间排队的自动登录
        if pendingAutoLogin {
            pendingAutoLogin = false
            runSkill("auto_login", source: .ai)
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

        // 0.6s 一次 K 键短按 —— 与 MaaNTE auto_volleyball.py 的节奏一致
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 0.6, repeating: 0.6)
        timer.setEventHandler { [weak self] in
            guard let self, self.runningSkills.contains("volleyball") else { return }
            control.pressGameKey(.k, duration: 0.05)
        }
        timer.resume()
        volleyballTimer = timer
        appendSystem("🏐 排球循环运行中（每 0.6s 击球一次，再次点击或输入「停止」结束）")
    }

    /// 通用 UI 点击技能（自动领奖励 / 自动收家具）
    /// 真实链路：截图 → Vision OCR 定位「领取/收取」按钮 → 鼠标点击 →
    /// 等 UI 反应后重试，最多 N 轮；按钮消失即完成。
    private func performUIClickLoop(skill: AgentSkill, source: AgentInvokeSource, dryRun: Bool) {
        guard let mouse = makeMouse() else {
            appendSystem("❌ 辅助功能权限未授权，无法注入鼠标")
            runningSkills.remove(skill.id)
            return
        }

        // 每种技能的关键词（按优先级）
        let keywords: [String]
        let maxRounds: Int
        let clickInterval: TimeInterval
        switch skill.id {
        case "rewards":
            keywords = ["一键领取", "领取奖励", "领取", "领奖", "确认"]
            maxRounds = 8
            clickInterval = 1.2
        case "furniture":
            keywords = ["一键收取", "收取家具", "收取", "回收"]
            maxRounds = 8
            clickInterval = 1.0
        default:
            keywords = []
            maxRounds = 0
            clickInterval = 1.0
        }

        let scale = MouseController.displayScale
        let logger: (String) -> Void = { [weak self] msg in
            self?.appendSystem(msg)
            self?.dlog("[\(skill.id)] \(msg)")
        }

        var clicked = 0
        for round in 1...maxRounds {
            // 技能可能被用户手工停止（runningSkills 被移除），循环感知退出
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
                // 找不到按钮 = 领完了/收完了，或界面不在
                logger(clicked > 0
                       ? "🏁 完成：共点击 \(clicked) 次，界面上已无「\(skill.name)」按钮"
                       : "ℹ️ 未找到「\(skill.name)」按钮（需要先打开对应界面？）")
                runningSkills.remove(skill.id)
                return
            }

            guard !dryRun else {
                // 自测：只验证定位链路，不真点
                logger("✅ 自测：定位到「\(hit.text)」→ (\(Int(hit.point.x)), \(Int(hit.point.y)))，链路就绪")
                runningSkills.remove(skill.id)
                return
            }

            logger("🖱️ 第 \(round) 轮：点击「\(hit.text)」")
            mouse.click(at: hit.point)
            clicked += 1
            usleep(useconds_t(clickInterval * 1_000_000))
        }

        // 到达轮数上限仍未结束（理论上按钮会消失；兜底停止）
        logger("⏹️ 已达 \(maxRounds) 轮上限，停止（避免无限点击）")
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

        let maxRounds = 12
        appendSystem("🎣 钓鱼循环启动：F 抛竿/收杆 × \(maxRounds) 轮（点击技能可停止）")
        for round in 1...maxRounds {
            guard runningSkills.contains(skill.id) else {
                appendSystem("⏹️ 钓鱼已停止")
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

        let maxRounds = 20
        appendSystem("⚔️ 闪避循环启动：周期性跳+疾跑闪避 × \(maxRounds) 轮（点击技能可停止）")
        for round in 1...maxRounds {
            guard runningSkills.contains(skill.id) else {
                appendSystem("⏹️ 闪避已停止")
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

        let mouse = makeMouse()
        let maxRounds = 15
        appendSystem("📜 自动滚动启动：F 连点 + 滚轮 × \(maxRounds) 轮（点击技能可停止）")
        for round in 1...maxRounds {
            guard runningSkills.contains(skill.id) else {
                appendSystem("⏹️ 滚动已停止")
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
        appendSystem("⚙️ 「\(skill.name)」：该技能依赖 MaaNTE 视觉管线（Windows），macOS 原生版开发中。\(snapshotInfo)")
        runningSkills.remove(skill.id)
    }

    // MARK: - 技能收尾

    private func teardown(id: String) {
        switch id {
        case "volleyball":
            volleyballTimer?.cancel()
            volleyballTimer = nil
        case "auto_login":
            loginWatchTimer?.cancel()
            loginWatchTimer = nil
            loginWatchAttempts = 0
        default:
            break
        }
    }

    // MARK: - AI 对话入口

    /// 用户输入一条消息（人类在输入框打字 / AI 面板收到指令）
    /// 统一从这里解析：能识别出技能 → 走 runSkill（同一通道）；否则本地回复
    func sendUserMessage(_ text: String, source: AgentInvokeSource) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(AgentMessage(role: .user, text: trimmed, time: Date(), source: source))
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
            workQueue.async { [weak self] in
                let semaphore = DispatchSemaphore(value: 0)
                var summary = ""
                Task {
                    summary = await loop.handle(task: task, from: source) { msg in
                        DispatchQueue.main.async { self?.appendSystem(msg) }
                    }
                    semaphore.signal()
                }
                semaphore.wait()
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

        // 本地命令回复（未接入外部 LLM 时的诚实行为）
        replyAssistant(localReply(to: trimmed))
    }

    /// 判断是否为需要端到端规划的复合任务
    /// 规则：单技能但无顺序词 → 单技能直配；含顺序词（然后/先/再/依次）→ 复合任务
    private func isComplexTask(_ text: String) -> Bool {
        let lower = text.lowercased()
        let sequentialWords = ["然后", "接着", "先", "再", "依次", "最后", "顺"]
        return sequentialWords.contains { lower.contains($0) }
    }

    /// 本地回复：状态汇总 + 可执行指令提示
    private func localReply(to text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("状态") || lower.contains("在干嘛") || lower.contains("忙什么") {
            let running = runningSkills.isEmpty ? "无" : runningSkills.map { id in
                AgentSkillLibrary.all.first(where: { $0.id == id })?.name ?? id
            }.joined(separator: "、")
            return "当前运行中：\(running)。模型：\(currentModel.rawValue)，思考强度：\(thinkingDepth)。"
        }
        if lower.contains("你好") || lower.contains("hi") || lower.contains("嗨") {
            return "你好！我可以帮你自动登录、打排球，或执行钓鱼/咖啡/钢琴等技能（后几项待移植）。试试输入「登录」或点左侧技能按钮。"
        }
        if lower.contains("模型") {
            return "当前模型：\(currentModel.rawValue)。可在输入框下方模型按钮切换。"
        }
        if lower.contains("帮助") || lower.contains("help") {
            let skills = AgentSkillLibrary.all.map { $0.name }.joined(separator: "、")
            return "可用技能：\(skills)。直接输入技能名即可调用（如「登录」「排球」「钓鱼」）。"
        }
        return "收到。这句话我暂未找到对应技能（当前为本地模式，未接入外部大模型 API）。试试：登录 / 排球 / 停止。"
    }

    private func replyAssistant(_ text: String) {
        messages.append(AgentMessage(role: .assistant, text: text, time: Date(), source: .ai))
    }

    func appendSystem(_ text: String) {
        messages.append(AgentMessage(role: .system, text: text, time: Date(), source: .ai))
    }

    // MARK: - 工具

    private func makeMouse() -> MouseController? {
        guard let control, control.hasAccessibilityPermission else { return nil }
        return MouseController()
    }

    /// 调试日志：stdout + /tmp/aurora_debug.log（与 DriveState.dlog 同款策略）
    private func dlog(_ msg: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(msg)"
        print(line)
        let url = URL(fileURLWithPath: "/tmp/aurora_debug.log")
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            }
        } else {
            try? data.write(to: url)
        }
    }

    /// 新建对话（清空会话，保留欢迎语）
    func newConversation() {
        messages.removeAll()
        messages.append(AgentMessage(role: .system,
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
                    .font(.system(size: 13, weight: .bold))
                    .rotationEffect(.degrees(center.isPanelOpen ? 180 : 0))
                    .foregroundStyle(Theme.cyan)
            }
            .frame(width: 22, height: 76)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(hovering ? Theme.cyan.opacity(0.7) : Theme.cyan.opacity(0.35),
                                  lineWidth: 1.2)
            )
            .shadow(color: hovering ? Theme.cyan.opacity(0.6) : Theme.cyan.opacity(0.25),
                    radius: hovering ? 14 : 7)
            .overlay(alignment: .leading) {
                // 左侧发光边条（呼吸感）
                Rectangle()
                    .fill(Theme.cyan.opacity(0.8))
                    .frame(width: 2)
                    .shadow(color: Theme.cyan, radius: 4)
            }
        }
        .buttonStyle(.plain)
        .help("AI 助手（\(center.isPanelOpen ? "收起" : "展开")）")
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovering = h }
        }
        // 箭头跟随面板位置：收起贴屏幕左缘，展开移到面板右侧边缘
        // （面板是 HStack 首元素占 348pt，箭头不能叠在面板上）
        .padding(.leading, 2)
        .offset(x: center.isPanelOpen ? panelWidth : 0)
        .zIndex(20)
    }
}

/// AI Agent 面板（左侧滑出，占屏约 1/4，独立开关）
struct AIAgentPanelView: View {
    @Bindable var center: AgentSkillCenter

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    @State private var draftText = ""
    @State private var showModelPicker = false
    @State private var appeared = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // ── 头部：图标 + 标题 + 状态点 ──
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.cyan.opacity(0.35), Theme.cyan.opacity(0.08)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 30, height: 30)
                    Text("🤖")
                        .font(.system(size: 16))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("AI AGENT")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .tracking(1.6)
                            .foregroundStyle(Theme.textPrimary)
                        Circle()
                            .fill(center.runningSkills.isEmpty ? Theme.cyan : Theme.orangeRed)
                            .frame(width: 6, height: 6)
                            .shadow(color: center.runningSkills.isEmpty ? Theme.cyan : Theme.orangeRed,
                                    radius: 4)
                    }
                    Text(center.runningSkills.isEmpty
                         ? "空闲 · \(center.currentModel.rawValue)"
                         : "运行中 · \(runningNames)")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
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
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
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
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("收起 AI 面板")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .opacity(appeared ? 1 : 0)
            .offset(x: appeared ? 0 : -24)
            .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.03), value: appeared)

            // ── 技能网格（人类点 = AI 也能调，同一通道）──
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(AgentSkillLibrary.all) { skill in
                    AgentSkillButton(skill: skill,
                                     active: center.runningSkills.contains(skill.id),
                                     action: {
                        center.toggleSkill(skill.id, source: .human)
                    })
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // ── 对话区（单对话，无历史列表）──
            AgentConversationView(center: center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)

            // ── 输入区 ──
            agentInputArea
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            // ── 底部：新建对话 + 状态条 ──
            HStack(spacing: 8) {
                Button {
                    center.newConversation()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11))
                        Text("新建对话")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.cyan.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(Theme.cyan.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer()
                Text(center.messages.last?.text.prefix(28) ?? "")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .opacity(appeared ? 1 : 0)
            .animation(.easeOut(duration: 0.25).delay(0.18), value: appeared)
        }
        .frame(width: 348)
        .background(
            ZStack {
                Color.black.opacity(0.92)
                LinearGradient(colors: [Theme.cyan.opacity(0.06), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        )
        .overlay(alignment: .trailing) {
            // 面板右侧发光分隔线
            Rectangle()
                .fill(LinearGradient(colors: [Theme.cyan.opacity(0.5), Theme.cyan.opacity(0.06)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                appeared = true
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
        VStack(spacing: 8) {
            // 输入框
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if draftText.isEmpty {
                        Text("给 AI 下达指令，或直接输入技能名…")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 9)
                            .padding(.leading, 10)
                    }
                    TextEditor(text: $draftText)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 62)
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))

                Button {
                    sendDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(draftText.isEmpty ? Theme.textTertiary : Theme.cyan)
                }
                .buttonStyle(.plain)
                .disabled(draftText.isEmpty)
            }

            // 第二行：模型按钮 + 思考滑块
            HStack(spacing: 10) {
                // 模型选择
                Menu {
                    ForEach(AgentModel.allCases) { model in
                        Button {
                            center.currentModel = model
                            showModelPicker = false
                        } label: {
                            if model == center.currentModel {
                                Label(model.rawValue, systemImage: "checkmark")
                            } else {
                                Text(model.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .font(.system(size: 9))
                        Text(center.currentModel.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7))
                    }
                    .foregroundStyle(Theme.cyan)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.cyan.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(Theme.cyan.opacity(0.35), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // 思考强度滑块
                HStack(spacing: 6) {
                    Text("思考")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Slider(value: Binding(
                        get: { Double(center.thinkingDepth) },
                        set: { center.thinkingDepth = Int($0.rounded()) }
                    ), in: 1...10, step: 1)
                        .controlSize(.mini)
                        .frame(width: 84)
                    Text("\(center.thinkingDepth)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.cyan)
                        .frame(width: 12)
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

// MARK: - AI 配置 Sheet

struct AgentSettingsSheet: View {
    @Bindable var center: AgentSkillCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("API 配置（安全存 Keychain）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key — 粘贴你的 DeepSeek/OpenAI/Claude API Key")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                        TextField("sk-...", text: $center.aiSettings.apiKey,
                                  prompt: Text("sk-xxxxxxxx"))
                            .font(.system(.body, design: .monospaced))
                            .textContentType(.password)
                            .autocorrectionDisabled(true)
                        Text("存储在 macOS Keychain，不写磁盘明文")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                Section("端点 & 模型") {
                    TextField("Base URL", text: $center.aiSettings.baseUrl,
                              prompt: Text("https://api.deepseek.com"))
                        .font(.system(.body, design: .monospaced))
                    TextField("Model", text: $center.aiSettings.model,
                              prompt: Text("deepseek-chat"))
                        .font(.system(.body, design: .monospaced))
                    Picker("思考深度", selection: $center.aiSettings.thinkingDepth) {
                        Text("低 (1)").tag(1)
                        Text("中 (3)").tag(3)
                        Text("高 (5)").tag(5)
                    }
                    .pickerStyle(.segmented)
                }

                Section("快速填充（示例配置）") {
                    Button("DeepSeek 默认") {
                        center.aiSettings = AgentSettings(
                            apiKey: "",
                            baseUrl: "https://api.deepseek.com",
                            model: "deepseek-chat",
                            thinkingDepth: 3
                        )
                    }
                    Button("OpenAI") {
                        center.aiSettings = AgentSettings(
                            apiKey: "",
                            baseUrl: "https://api.openai.com",
                            model: "gpt-4o-mini",
                            thinkingDepth: 3
                        )
                    }
                    Button("Anthropic Claude") {
                        center.aiSettings = AgentSettings(
                            apiKey: "",
                            baseUrl: "https://api.anthropic.com",
                            model: "claude-3-5-haiku-20241022",
                            thinkingDepth: 5
                        )
                    }
                }
            }
            .navigationTitle("AI 配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            try center.aiSettings.save()
                            center.appendSystem("✅ API Key 已安全保存（Keychain）")
                            dismiss()
                        } catch {
                            center.appendSystem("❌ 保存失败：\(error.localizedDescription)")
                        }
                    }
                    .disabled(center.aiSettings.apiKey.isEmpty)
                }
            }
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
            VStack(spacing: 4) {
                Text(skill.emoji)
                    .font(.system(size: 17))
                    .shadow(color: hovered ? Theme.cyan.opacity(0.9) : .clear, radius: hovered ? 9 : 0)
                Text(skill.name)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                HStack(spacing: 3) {
                    if !skill.ported {
                        Text("待移植")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Circle()
                        .fill(active ? Theme.cyan : (skill.warn ? Theme.danger : Color.white.opacity(0.15)))
                        .frame(width: 5, height: 5)
                        .shadow(color: active ? Theme.cyan : .clear, radius: active ? 4 : 0)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(active ? Theme.cyan.opacity(0.12)
                                     : (hovered ? Theme.cyan.opacity(0.08) : Color.white.opacity(0.04)))
                    if hovered || active {
                        RadialGradient(colors: [Theme.cyan.opacity(0.14), .clear],
                                       center: .center, startRadius: 0, endRadius: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovered || active ? Theme.cyan.opacity(0.55) : Color.white.opacity(0.08),
                                  lineWidth: 1)
            )
            .shadow(color: hovered ? Theme.cyan.opacity(0.35) : .clear, radius: hovered ? 10 : 0)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovered = h }
        }
        .help("\(skill.name)\(skill.ported ? "（点击启动/停止）" : "（待移植，点击会报告当前状态）")")
    }
}

/// 对话视图（单对话流，滚动）
private struct AgentConversationView: View {
    @Bindable var center: AgentSkillCenter

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(center.messages) { msg in
                        AgentBubble(msg: msg)
                            .id(msg.id)
                    }
                }
                .padding(.vertical, 6)
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
            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(timeLabel)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    Text(msg.source.rawValue)
                        .font(.system(size: 8))
                }
                Text(msg.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(roleColor)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(bubbleFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
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
        case .user: return Theme.textPrimary
        case .assistant: return Theme.cyan
        case .system: return Theme.textSecondary
        }
    }

    private var bubbleFill: Color {
        switch msg.role {
        case .user: return Theme.cyan.opacity(0.10)
        case .assistant: return Theme.cyan.opacity(0.06)
        case .system: return Color.white.opacity(0.04)
        }
    }

    private var bubbleBorder: Color {
        switch msg.role {
        case .user: return Theme.cyan.opacity(0.30)
        case .assistant: return Theme.cyan.opacity(0.22)
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
            .background(Theme.bgPure)
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
            VStack(alignment: .leading, spacing: 4) {
                Text("GAME VIEWPORT（主 UI，右移后保持可见）")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text("↖ 网络地图/小地图在这里，永不遮挡")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.cyan)
            }
        }
        let sidebarPlaceholder = ZStack {
            Rectangle().fill(Color(red: 0.08, green: 0.09, blue: 0.11))
            Text("SIDEBAR 360pt").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
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
        let combo = VStack(spacing: 12) {
            Text("折叠（主 UI 占满，箭头在左缘）")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
            collapsed
            Text("展开（面板占左 348，主 UI 右移，箭头在面板右缘）")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.cyan)
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
