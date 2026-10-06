// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  ToolRegistry.swift — AI 工具挂载注册表（W4 · A3「自主调工具」核心交付）
// ============================================================================
//
//  【这个文件解决什么问题】
//    AI 助手此前只有一套「技能现场拼 toolDecl」（AIAgentPanel.swift:265-289）：
//    只有技能、没有参数、没有键位/鼠标/文本/观察/搜索工具，且聊天路径与
//    AgentLoop 路径各拼一份。本文件是**唯一**的工具清单与执行入口：
//      · 一份挂载表 → LLM function calling 规格（`specs()`）
//      · 一个执行入口 → 真实注入 / 真实验证（`invoke`）
//      · 一条证据链 → 每次调用发出的事件数（`ToolResult.postedEvents`）
//
//  【挂载清单：30 个工具，一个不少】
//    · 技能 18  `skill__*`                  → AgentSkillCenter.runSkill(id:source:.ai)
//    · 键位  4  press/hold/release/release_all → ControlEngine(GameKey)
//    · 文本  1  type_text                   → ControlEngine.typeText
//    · 鼠标  3  mouse_move/click/scroll      → MouseController
//    · 观察  2  screenshot / get_status
//    · 搜索  2  web_search / web_fetch       → W5 `WebSearch`（本文件**不**实现抓取）
//
//  【护栏：四道，全部「明确报错、不静默」】
//    ① `AuroraFlags.observeOnly`（AURORA_OBSERVE_ONLY=1）→ 拒绝一切注入类工具（ok=false）
//    ② `GameWindowDetector.isGameVisible()` → 游戏不可见拒绝（防止把键鼠注进别的窗口）
//    ③ `AXIsProcessTrusted()` → 辅助功能未授权拒绝（事件会被系统静默丢弃，绝不假装成功）
//    ④ `dryRun` → 不真注入，但返回**结构完整**的 ToolResult（供 W8 自检逐项校验）
//
//  【dryRun 与护栏的关系（设计决定，写清楚免得被误读）】
//    dryRun 不注入任何事件，因此护栏②③**不拦截** dryRun（否则在无游戏窗口的
//    自检环境里永远拿不到 ok=true 的结构化结果，自检只剩一堆拒绝文本）。
//    观测模式①不拦截 dryRun，但真实调用时照常拒绝 —— 这是**故意**的决策，违反即
//    失去「无副作用自检」能力。dryRun 的返回文本里会如实标注它没做任何事。
//
//  【postedEvents 的确切语义（A2/A3 证据字段）】
//    = 本次 invoke 返回前观测到的 CGEvent 增量 =
//        (ControlEngine.postedEventCount 差值) + (MouseController.postedEventCount 差值)
//    · 注入类工具（键位/文本/鼠标）：精确等于本次注入数（0 = 一个事件都没发出去）
//    · 技能类工具：技能在 AgentSkillCenter 的 workQueue 异步执行，这里的数字是
//      「启动后 250ms 窗口内观测到的注入数」，可能为 0（技能还在 OCR 定位/等待），
//      **0 不代表技能失败**；要判断技能是否在跑请用 `get_status`。
//
//  【引擎从哪来（写作用域限制下的接线说明）】
//    本文件只允许写自己，不能改 AIAgentPanel.swift（其 `control`/`capture` 是
//    private，跨文件不可见）。因此引擎解析顺序：
//      ① `attach(control:capture:)` 显式注入 —— 推荐，零副作用
//      ② 回退 `DriveState.shared.controlEngine / captureEngine / currentFrameCG`
//         （GUI 里该单例已构造，回退零成本；CLI 一次性自检若走到真实注入会触发
//          该单例的惰性构造，故 dryRun 路径在解析引擎**之前**就短路返回）
//
//  【线程模型】
//    注册表是 actor：清单只读、执行串行。引擎（ControlEngine/MouseController/
//    CaptureEngine）本身是 `@unchecked Sendable` 且内部带锁，可直接从 actor 调用；
//    只有 `DriveState`（@MainActor）与 `AgentSkillCenter` 的 UI 状态需要跳主线程。
//    任何网络（web_search/web_fetch）都在 W5 的 actor 内，不碰主线程。
// ============================================================================

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - 工具描述

/// 一个可被 AI 调用的工具（挂载表的一行）
///
/// schema 存**序列化后的 JSON 字符串**而不是 `[String: Any]`：
///   ① 结构体因此是纯 Sendable，可以安全跨 actor 传出（自检要拿它逐个验 schema）；
///   ② 能直接喂给 `LLMToolSpec(name:description:parametersJSON:)`，不做二次序列化。
struct AgentTool: Sendable, Equatable {
    /// 工具名：喂给模型的唯一标识（也是 invoke 的分发键）
    let name: String
    /// 给模型看的用途说明（中文，含触发场景与风险提示）
    let description: String
    /// 参数的 JSON Schema（object 根的序列化串）
    let schemaJSON: String
    /// true = 执行前必须确认游戏窗口可见（防误注入到别的应用）
    let requiresGame: Bool
    /// false = 已登记但代码库中未移植（调用返回 ok=false，不做假动作）
    let isImplemented: Bool
    /// true = 会向系统注入键鼠事件（受 观测模式 / AX 权限 / dryRun 三重护栏）
    let isInjection: Bool
}

/// 一次工具调用的结果（回传给模型 + 供自检断言）
struct ToolResult: Sendable, Equatable {
    /// 工具名
    let tool: String
    /// 是否成功（护栏拒绝 / 参数非法 / 未知工具一律 false，并给明确原因）
    let ok: Bool
    /// 人话结果或失败原因（可直接进对话 history 当 summary）
    let text: String
    /// 本次是否干跑（true = 没有注入任何事件）
    let dryRun: Bool
    /// 本次调用观测到的事件增量（语义见文件头注释；A2/A3 证据字段）
    let postedEvents: Int

    static func success(_ tool: String, _ text: String, dryRun: Bool = false, postedEvents: Int = 0) -> ToolResult {
        ToolResult(tool: tool, ok: true, text: text, dryRun: dryRun, postedEvents: postedEvents)
    }

    static func failure(_ tool: String, _ text: String, dryRun: Bool = false, postedEvents: Int = 0) -> ToolResult {
        ToolResult(tool: tool, ok: false, text: text, dryRun: dryRun, postedEvents: postedEvents)
    }
}

/// 参数校验/内部前置条件失败（内部用；在 invoke 里统一转成 ok=false + 明确原因）
private struct ToolFailure: Error {
    let message: String
}

// MARK: - 工具注册表

/// AI 工具注册表（单例 actor）
actor ToolRegistry {

    /// 进程内单例（与项目既有 convention 一致：`*.shared`）
    static let shared = ToolRegistry()

    // ── 挂载表 ──
    private var tools: [String: AgentTool] = [:]
    private var order: [String] = []
    /// 注册期发现的问题（正常恒为空；由 selfCheck() 暴露，绝不静默）
    private var registrationErrors: [String] = []

    // ── 引擎 ──
    /// 显式注入的引擎（优先）
    private var attachedControl: ControlEngine?
    private var attachedCapture: CaptureEngine?
    /// 鼠标注入器（复用一个实例，保证 postedEventCount 连续可做差值）
    private var mouse: MouseController?

    private init() {}

    // MARK: - 接线

    /// 显式注入引擎（GUI/CLI 接线方推荐调用一次；之后不再回退 DriveState.shared）
    func attach(control: ControlEngine? = nil, capture: CaptureEngine? = nil) {
        if let control { attachedControl = control }
        if let capture { attachedCapture = capture }
    }

    // MARK: - 注册

    /// 注册全部工具（幂等；所有公开入口都会先调用一次）
    func registerAll() {
        guard tools.isEmpty else { return }
        registrationErrors.removeAll()

        // ── ① 18 个技能工具（id 与 AgentSkillLibrary 逐字对齐）──
        for skill in AgentSkillLibrary.all {
            insert(AgentTool(
                name: "skill__\(skill.id)",
                description: Self.skillToolDescription(skill),
                schemaJSON: Self.noArgSchema,
                requiresGame: true,
                isImplemented: skill.ported,   // preset_realtime: ported=false → 调用返回 ok=false
                isInjection: true))            // 技能底层会注入键鼠（rewards/furniture 是 UI 点击）
        }

        // ── ② 键位工具（key 取值 = ControlEngine.GameKey 的全部 case）──
        let keys = Self.gameKeyListText
        insert(AgentTool(
            name: "press_key",
            description: "短按一个游戏键（按下→释放）。用于交互、确认、跳跃等单次按键。可用键：\(keys)",
            schemaJSON: Self.schemaJSON(
                properties: [
                    "key": [
                        "type": "string",
                        "description": "按键名，取值：\(keys)（大小写不敏感）",
                        "enum": Self.gameKeyNames,
                    ],
                    "duration": [
                        "type": "number",
                        "description": "按下时长（秒），默认 0.05，范围 0–2",
                    ],
                ],
                required: ["key"]),
            requiresGame: true, isImplemented: true, isInjection: true))
        insert(AgentTool(
            name: "hold_key",
            description: "持续按住一个游戏键（不自动释放），直到 release_key 或 release_all_keys。"
                + "用于移动/持续油门等需要长按的场景。可用键：\(keys)",
            schemaJSON: Self.schemaJSON(
                properties: [
                    "key": [
                        "type": "string",
                        "description": "按键名，取值：\(keys)（大小写不敏感）",
                        "enum": Self.gameKeyNames,
                    ],
                ],
                required: ["key"]),
            requiresGame: true, isImplemented: true, isInjection: true))
        insert(AgentTool(
            name: "release_key",
            description: "释放一个此前被 hold_key 按住的游戏键。可用键：\(keys)",
            schemaJSON: Self.schemaJSON(
                properties: [
                    "key": [
                        "type": "string",
                        "description": "按键名，取值：\(keys)（大小写不敏感）",
                        "enum": Self.gameKeyNames,
                    ],
                ],
                required: ["key"]),
            requiresGame: true, isImplemented: true, isInjection: true))
        insert(AgentTool(
            name: "release_all_keys",
            description: "释放所有被按住的游戏键（安全兜底：动作结束或异常时务必调用，避免按键卡住）",
            schemaJSON: Self.noArgSchema,
            requiresGame: true, isImplemented: true, isInjection: true))

        // ── ③ 文本工具 ──
        insert(AgentTool(
            name: "type_text",
            description: "向当前获得键盘焦点的输入框注入一段文本（Unicode）。"
                + "注意：文字进入「当前焦点输入框」，通常需要先用 press_key(F 或 Enter) 打开游戏聊天框。",
            schemaJSON: Self.schemaJSON(
                properties: ["text": ["type": "string", "description": "要输入的文本内容（非空，超长截断到 500 字符）"]],
                required: ["text"]),
            requiresGame: true, isImplemented: true, isInjection: true))

        // ── ④ 鼠标工具（坐标为屏幕全局点，左上原点，单位点）──
        let coordNote = "坐标为屏幕全局点（左上原点、单位点）：截图像素 ÷ 显示器 backingScaleFactor"
            + "（Retina 通常 2.0）= 本坐标。"
        insert(AgentTool(
            name: "mouse_move",
            description: "把鼠标移动到屏幕指定坐标（不点击）。\(coordNote)",
            schemaJSON: Self.schemaJSON(
                properties: [
                    "x": ["type": "number", "description": "横坐标（点）"],
                    "y": ["type": "number", "description": "纵坐标（点）"],
                ],
                required: ["x", "y"]),
            requiresGame: true, isImplemented: true, isInjection: true))
        insert(AgentTool(
            name: "mouse_click",
            description: "在屏幕指定坐标左键单击（先移动再按下→释放）。\(coordNote)",
            schemaJSON: Self.schemaJSON(
                properties: [
                    "x": ["type": "number", "description": "横坐标（点）"],
                    "y": ["type": "number", "description": "纵坐标（点）"],
                ],
                required: ["x", "y"]),
            requiresGame: true, isImplemented: true, isInjection: true))
        insert(AgentTool(
            name: "mouse_scroll",
            description: "滚动鼠标滚轮（正值向下、负值向上；一格约 ±120）。用于翻页、滚动拾取。",
            schemaJSON: Self.schemaJSON(
                properties: ["lines": ["type": "integer", "description": "滚动量（正=向下，负=向上；范围 -1000…1000）"]],
                required: ["lines"]),
            requiresGame: true, isImplemented: true, isInjection: true))

        // ── ⑤ 观察工具（不注入，随时可调）──
        insert(AgentTool(
            name: "screenshot",
            description: "抓取当前游戏画面帧并存成 JPEG 文件，返回文件路径与尺寸。"
                + "用于「看不清当前状态」时先看一眼再决定动作。工具结果默认只回文本与文件路径，"
                + "画面要不要发给模型由面板的「📷 视觉」开关决定（避免把兆级 base64 塞进上下文）。",
            schemaJSON: Self.schemaJSON(
                properties: ["includeData": ["type": "boolean",
                                             "description": "true=额外回传 base64 data URI（仅当 base64 ≤300000 字符时；默认 false）"]],
                required: []),
            requiresGame: false, isImplemented: true, isInjection: false))
        insert(AgentTool(
            name: "get_status",
            description: "查询当前运行状态：游戏窗口是否可见、辅助功能是否授权、观测模式、"
                + "正在运行的技能、最近任务、模型/渠道配置、累计注入事件数。动作前先看一眼可避免误操作。",
            schemaJSON: Self.noArgSchema,
            requiresGame: false, isImplemented: true, isInjection: false))

        // ── ⑥ 搜索工具（实现由 W5 WebSearch.swift 提供；本文件只做参数校验与结果格式化）──
        insert(AgentTool(
            name: "web_search",
            description: "联网搜索公开网页（DuckDuckGo Lite，失败自动回退 Wikipedia）。"
                + "用于查游戏攻略、机制说明、实时信息。只读抓取，不登录、不绕验证码。",
            schemaJSON: Self.schemaJSON(
                properties: [
                    "query": ["type": "string", "description": "搜索词（非空）"],
                    "maxResults": ["type": "integer", "description": "返回条数上限，默认 5，范围 1–20"],
                ],
                required: ["query"]),
            requiresGame: false, isImplemented: true, isInjection: false))
        insert(AgentTool(
            name: "web_fetch",
            description: "抓取一个公开网页的正文并转成纯文本（默认截断 8000 字符）。用于读完搜索结果里的某一页。",
            schemaJSON: Self.schemaJSON(
                properties: [
                    "url": ["type": "string", "description": "http/https 开头的完整 URL"],
                    "maxCharacters": ["type": "integer", "description": "正文最大字符数，默认 8000，范围 500–20000"],
                ],
                required: ["url"]),
            requiresGame: false, isImplemented: true, isInjection: false))

        // 注册期自检：schema 必须是合法 JSON 且根为 object（编译期常量，正常恒为空）
        for name in order {
            guard let tool = tools[name] else { continue }
            guard let data = tool.schemaJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                registrationErrors.append("schema 不是合法 JSON 对象：\(name)")
                continue
            }
            if (obj["type"] as? String) != "object" {
                registrationErrors.append("schema 根 type 必须是 object：\(name)")
            }
            if obj["properties"] == nil {
                registrationErrors.append("schema 缺少 properties：\(name)")
            }
        }
    }

    // MARK: - 对外查询

    /// 全部工具名（注册顺序；含未移植的 `skill__preset_realtime`）
    func allToolNames() -> [String] {
        registerAll()
        return order
    }

    /// 全部工具（含 schema 串；供自检验证 JSON Schema 合法性）
    func allTools() -> [AgentTool] {
        registerAll()
        return order.compactMap { tools[$0] }
    }

    /// 单个工具
    func tool(named name: String) -> AgentTool? {
        registerAll()
        return tools[name]
    }

    /// 工具总数
    func toolCount() -> Int {
        registerAll()
        return order.count
    }

    /// 自检：返回问题清单（空数组 = 一切正常）
    func selfCheck() -> [String] {
        registerAll()
        var problems = registrationErrors

        // ① 技能一一对齐：库里的每个技能都必须有对应工具
        for skill in AgentSkillLibrary.all where tools["skill__\(skill.id)"] == nil {
            problems.append("缺少技能工具：skill__\(skill.id)")
        }
        // ② 反向核对：每个 skill__ 工具名都必须能对上库里真实的技能 id（防拼写漂移）
        for name in order where name.hasPrefix("skill__") {
            let id = String(name.dropFirst("skill__".count))
            if AgentSkillLibrary.all.first(where: { $0.id == id }) == nil {
                problems.append("工具名对不上任何技能 id：\(name)")
            }
        }
        // ③ 规格构建必须不丢工具（specs 与注册表数量一致）
        if specs().count != order.count {
            problems.append("specs() 数量 \(specs().count) ≠ 注册数 \(order.count)")
        }
        // ④ 注入类工具必须声明 requiresGame（防止漏护栏）
        for tool in allTools() where tool.isInjection && !tool.requiresGame {
            problems.append("注入类工具未声明 requiresGame：\(tool.name)")
        }
        return problems
    }

    /// 工具规格（喂 LLMTransport.tools；类型与 W2 的 `LLMToolSpec` 完全一致）
    ///
    /// 【为什么把未移植的 preset_realtime 也发给模型】
    ///   挂载清单要求「一个不少」，且模型幻觉需要可验证的闭合点：它调用了未移植技能
    ///   会拿到明确的 ok=false + 原因（描述里已标注「未移植」），比让工具凭空消失、
    ///   模型反复试错更可控。
    func specs() -> [LLMToolSpec] {
        registerAll()
        var out: [LLMToolSpec] = []
        out.reserveCapacity(order.count)
        for name in order {
            guard let tool = tools[name] else { continue }
            out.append(LLMToolSpec(name: tool.name,
                                   description: tool.description,
                                   parametersJSON: tool.schemaJSON))
        }
        return out
    }

    // MARK: - 统一入口

    /// 执行一个工具调用（永不 throws；失败一律 ok=false + 中文原因）
    func invoke(name: String, args: [String: String] = [:], dryRun: Bool = false) async -> ToolResult {
        registerAll()

        guard let tool = tools[name] else {
            return .failure(name, "未知工具「\(name)」，未执行任何动作", dryRun: dryRun)
        }

        guard tool.isImplemented else {
            return .failure(name,
                            "工具「\(name)」在当前代码库中标记为未移植（ported:false），未执行任何动作",
                            dryRun: dryRun)
        }

        // ── 护栏（只对真实注入生效；dryRun 不注入任何事件，见文件头说明）──
        if tool.isInjection && !dryRun {
            if AuroraFlags.observeOnly {
                return .failure(name,
                                "观测模式（AURORA_OBSERVE_ONLY=1）禁止输入注入，本次未发送任何事件",
                                dryRun: false)
            }
            if tool.requiresGame && !GameWindowDetector.isGameVisible() {
                return .failure(name,
                                "未检测到游戏窗口（异环/NTE），拒绝注入以免误操作其他应用",
                                dryRun: false)
            }
            if !AXIsProcessTrusted() {
                return .failure(name,
                                "辅助功能权限未授权，事件会被系统丢弃。"
                                + "请在 系统设置 → 隐私与安全性 → 辅助功能 勾选本程序后重启（本次未发送任何事件）",
                                dryRun: false)
            }
        }

        do {
            return try await dispatch(tool: tool, args: args, dryRun: dryRun)
        } catch let failure as ToolFailure {
            return .failure(name, failure.message, dryRun: dryRun)
        } catch {
            return .failure(name, "工具执行异常：\(error)", dryRun: dryRun)
        }
    }

    /// 执行一个工具调用（参数为模型返回的原始 arguments JSON 串）
    ///
    /// 解析失败 → ok=false + 明确原因（不猜、不吞）。标量统一转字符串，
    /// 由各工具按需解析数字/布尔。空串视为「无参数」。
    func invoke(name: String, argumentsJSON: String, dryRun: Bool = false) async -> ToolResult {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null" else {
            return await invoke(name: name, args: [:], dryRun: dryRun)
        }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return .failure(name, "arguments 不是合法 JSON 对象：\(String(trimmed.prefix(200)))", dryRun: dryRun)
        }
        var args: [String: String] = [:]
        for (key, value) in dict {
            switch value {
            case let string as String: args[key] = string
            case let number as NSNumber: args[key] = number.stringValue
            case is NSNull: continue
            default: args[key] = "\(value)"
            }
        }
        return await invoke(name: name, args: args, dryRun: dryRun)
    }

    // MARK: - 分发

    private func dispatch(tool: AgentTool, args: [String: String], dryRun: Bool) async throws -> ToolResult {
        // ① 技能
        if tool.name.hasPrefix("skill__") {
            let skillID = String(tool.name.dropFirst("skill__".count))
            return try await runSkillTool(skillID: skillID, toolName: tool.name, dryRun: dryRun)
        }
        // ② 其余按名分发
        switch tool.name {
        case "press_key":        return try await pressKey(args: args, dryRun: dryRun)
        case "hold_key":         return try await holdKey(args: args, dryRun: dryRun)
        case "release_key":      return try await releaseKey(args: args, dryRun: dryRun)
        case "release_all_keys": return await releaseAllKeys(dryRun: dryRun)
        case "type_text":        return try await typeText(args: args, dryRun: dryRun)
        case "mouse_move":       return try await mouseMove(args: args, dryRun: dryRun)
        case "mouse_click":      return try await mouseClick(args: args, dryRun: dryRun)
        case "mouse_scroll":     return try await mouseScroll(args: args, dryRun: dryRun)
        case "screenshot":       return try await screenshot(args: args, dryRun: dryRun)
        case "get_status":       return await getStatus(dryRun: dryRun)
        case "web_search":       return try await webSearch(args: args, dryRun: dryRun)
        case "web_fetch":        return try await webFetch(args: args, dryRun: dryRun)
        default:
            return .failure(tool.name, "工具「\(tool.name)」已登记但未实现分发（内部错误）", dryRun: dryRun)
        }
    }

    // MARK: - 技能工具

    private func runSkillTool(skillID: String, toolName: String, dryRun: Bool) async throws -> ToolResult {
        guard let skill = AgentSkillLibrary.all.first(where: { $0.id == skillID }) else {
            return .failure(toolName, "未知技能「\(skillID)」（工具名与 AgentSkillLibrary 对不上）", dryRun: dryRun)
        }
        guard skill.ported else {
            return .failure(toolName, "技能「\(skill.name)」未移植（ported:false），未启动", dryRun: dryRun)
        }
        if dryRun {
            return .success(toolName, "干跑：将启动技能「\(skill.emoji)\(skill.name)」（未执行任何动作）", dryRun: true)
        }

        // 启动前取样（引擎解析失败 = 0，不影响技能本身的启动语义）
        let before = await currentEventTotal()

        let refusal: String? = await MainActor.run {
            let center = AgentSkillCenter.shared
            if center.runningSkills.contains(skillID) {
                return "技能「\(skill.name)」已在运行中（目标状态已满足，未重复启动）"
            }
            center.runSkill(skillID, source: .ai)
            return nil
        }
        if let refusal {
            return .failure(toolName, refusal, dryRun: false)
        }

        // 技能在 workQueue 异步执行：取一个短窗口的注入增量作为「确实动起来了」的证据。
        // 0 不代表失败（可能还在 OCR 定位/等待），所以这里仍然 ok=true，由 get_status 兜底。
        try? await Task.sleep(nanoseconds: 250_000_000)
        let delta = max(0, await currentEventTotal() - before)

        let tail = delta > 0
            ? "启动后 250ms 内观测到 \(delta) 个注入事件（技能正在真实动作）"
            : "技能已进入后台执行队列；250ms 窗口内暂无注入事件（OCR 定位/等待阶段属正常，可用 get_status 查运行状态）"
        return .success(toolName, "已启动技能「\(skill.emoji)\(skill.name)」：\(tail)",
                        dryRun: false, postedEvents: delta)
    }

    // MARK: - 键位工具

    private func pressKey(args: [String: String], dryRun: Bool) async throws -> ToolResult {
        let key = try resolveGameKey(try requiredString(args, "key"))
        let duration = try optionalDouble(args, "duration", default: 0.05, range: 0...2)
        if dryRun {
            return .success("press_key", "干跑：将短按「\(key.rawValue)」\(Self.format(duration)) 秒（未注入）", dryRun: true)
        }
        let control = try await requireControl()
        let before = control.postedEventCount
        control.pressGameKey(key, duration: duration)
        let delta = control.postedEventCount - before
        return .success("press_key", "已短按「\(key.rawValue)」\(Self.format(duration)) 秒，注入 \(delta) 个事件",
                        dryRun: false, postedEvents: delta)
    }

    private func holdKey(args: [String: String], dryRun: Bool) async throws -> ToolResult {
        let key = try resolveGameKey(try requiredString(args, "key"))
        if dryRun {
            return .success("hold_key", "干跑：将按住「\(key.rawValue)」（未注入）", dryRun: true)
        }
        let control = try await requireControl()
        let before = control.postedEventCount
        control.holdGameKey(key)
        let delta = control.postedEventCount - before
        if delta == 0 {
            return .success("hold_key", "「\(key.rawValue)」此前已处于按住状态，未重复发送（held=\(control.isHeld(key))）",
                            dryRun: false, postedEvents: 0)
        }
        return .success("hold_key", "已按住「\(key.rawValue)」（held=\(control.isHeld(key))），注入 \(delta) 个事件；"
                        + "动作结束后记得调用 release_all_keys",
                        dryRun: false, postedEvents: delta)
    }

    private func releaseKey(args: [String: String], dryRun: Bool) async throws -> ToolResult {
        let key = try resolveGameKey(try requiredString(args, "key"))
        if dryRun {
            return .success("release_key", "干跑：将释放「\(key.rawValue)」（未注入）", dryRun: true)
        }
        let control = try await requireControl()
        let before = control.postedEventCount
        control.releaseGameKey(key)
        let delta = control.postedEventCount - before
        if delta == 0 {
            return .success("release_key", "「\(key.rawValue)」当前并未被按住，无需释放", dryRun: false, postedEvents: 0)
        }
        return .success("release_key", "已释放「\(key.rawValue)」，注入 \(delta) 个事件", dryRun: false, postedEvents: delta)
    }

    private func releaseAllKeys(dryRun: Bool) async -> ToolResult {
        if dryRun {
            return .success("release_all_keys", "干跑：将释放所有被按住的游戏键（未注入）", dryRun: true)
        }
        guard let control = await resolveControl() else {
            return .failure("release_all_keys", Self.noControlEngineText, dryRun: false)
        }
        let before = control.postedEventCount
        control.releaseAllGameKeys()
        let delta = control.postedEventCount - before
        return .success("release_all_keys", "已释放全部被按住的游戏键，注入 \(delta) 个事件",
                        dryRun: false, postedEvents: delta)
    }

    // MARK: - 文本工具

    private func typeText(args: [String: String], dryRun: Bool) async throws -> ToolResult {
        let text = try requiredString(args, "text")
        let clipped = String(text.prefix(500))
        if dryRun {
            return .success("type_text", "干跑：将输入 \(clipped.count) 个字符「\(clipped.prefix(40))」（未注入）", dryRun: true)
        }
        let control = try await requireControl()
        let before = control.postedEventCount
        control.typeText(clipped)
        let delta = control.postedEventCount - before
        let note = text.count > clipped.count ? "（原文本 \(text.count) 字符，已截断到 500）" : ""
        return .success("type_text", "已注入 \(clipped.count) 个字符\(note)（进入当前焦点输入框），注入 \(delta) 个事件",
                        dryRun: false, postedEvents: delta)
    }

    // MARK: - 鼠标工具

    private func mouseMove(args: [String: String], dryRun: Bool) async throws -> ToolResult {
        let point = try pointArgs(args)
        if dryRun {
            return .success("mouse_move", "干跑：将移动到 (\(Self.format(point.x)), \(Self.format(point.y)))（未注入）", dryRun: true)
        }
        let controller = mouseController()
        let before = controller.postedEventCount
        let ok = controller.move(to: point)
        let delta = controller.postedEventCount - before
        guard ok else {
            return .failure("mouse_move", "CGEvent 创建失败，鼠标未移动", dryRun: false, postedEvents: delta)
        }
        return .success("mouse_move", "已移动到 (\(Self.format(point.x)), \(Self.format(point.y)))，注入 \(delta) 个事件",
                        dryRun: false, postedEvents: delta)
    }

    private func mouseClick(args: [String: String], dryRun: Bool) async throws -> ToolResult {
        let point = try pointArgs(args)
        if dryRun {
            return .success("mouse_click", "干跑：将在 (\(Self.format(point.x)), \(Self.format(point.y))) 左键单击（未注入）", dryRun: true)
        }
        let controller = mouseController()
        let before = controller.postedEventCount
        let ok = controller.click(at: point)
        let delta = controller.postedEventCount - before
        guard ok else {
            return .failure("mouse_click", "CGEvent 创建失败，未点击", dryRun: false, postedEvents: delta)
        }
        return .success("mouse_click", "已在 (\(Self.format(point.x)), \(Self.format(point.y))) 左键单击，注入 \(delta) 个事件",
                        dryRun: false, postedEvents: delta)
    }

    private func mouseScroll(args: [String: String], dryRun: Bool) async throws -> ToolResult {
        guard let lines = try optionalInt(args, "lines", default: nil, range: -1000...1000) else {
            throw ToolFailure(message: "缺少必需参数 lines（滚动量：正=向下，负=向上）")
        }
        if dryRun {
            return .success("mouse_scroll", "干跑：将滚动 \(lines) 行（未注入）", dryRun: true)
        }
        let controller = mouseController()
        let before = controller.postedEventCount
        let ok = controller.scrollWheel(lines: Int32(lines))
        let delta = controller.postedEventCount - before
        guard ok else {
            return .failure("mouse_scroll", "CGEvent 创建失败，未滚动", dryRun: false, postedEvents: delta)
        }
        return .success("mouse_scroll", "已滚动 \(lines) 行（正=向下），注入 \(delta) 个事件",
                        dryRun: false, postedEvents: delta)
    }

    // MARK: - 观察工具

    private func screenshot(args: [String: String], dryRun: Bool) async throws -> ToolResult {
        let includeData = args["includeData"]?.lowercased() == "true" || args["includeData"] == "1"
        if dryRun {
            return .success("screenshot", "干跑：将抓取当前帧并编码/写出 JPEG（未抓取、未写盘）", dryRun: true)
        }
        guard let frame = await currentFrameCG() else {
            return .failure("screenshot",
                            "拿不到截屏帧：屏幕录制权限未授权，或采集引擎未启动/未接入",
                            dryRun: false)
        }
        guard let encoded = Self.encodeJPEG(frame) else {
            return .failure("screenshot", "帧编码失败（CGContext/JPEG 编码器不可用）", dryRun: false)
        }
        let url = Self.screenshotOutputURL()
        do {
            try encoded.data.write(to: url, options: .atomic)
        } catch {
            return .failure("screenshot", "JPEG 写盘失败：\(error.localizedDescription)", dryRun: false)
        }
        var text = "已抓取当前帧 \(frame.width)×\(frame.height) → JPEG \(encoded.width)×\(encoded.height)"
            + "（\(encoded.data.count / 1024) KB），存于 \(url.path)。"
            + "要让模型「看」这张图，请开启面板的「📷 视觉」开关（工具结果默认只回文本，避免兆级 base64 撑爆上下文）。"
        if includeData {
            let base64 = encoded.data.base64EncodedString()
            if base64.count <= 300_000 {
                text += "\n\ndata:image/jpeg;base64,\(base64)"
            } else {
                text += "\n\n（已请求 includeData，但 base64 长度 \(base64.count) > 300000，为保护上下文仅回文件路径）"
            }
        }
        return .success("screenshot", text, dryRun: false)
    }

    private func getStatus(dryRun: Bool = false) async -> ToolResult {
        // 先把 actor 状态取成局部常量，再跳主线程读 UI 侧状态（避免跨隔离读写）
        let attachedControlSnapshot = attachedControl
        let attachedCaptureSnapshot = attachedCapture
        let mouseEvents = mouse?.postedEventCount
        let toolNames = order

        let report: String = await MainActor.run {
            let center = AgentSkillCenter.shared
            let settings = center.aiSettings
            let running = center.runningSkills.sorted()
            let lastUser = center.messages.last(where: { $0.role == .user })?.text ?? "（无）"
            let gameVisible = GameWindowDetector.isGameVisible()
            let trusted = AXIsProcessTrusted()
            let observeOnly = AuroraFlags.observeOnly

            var lines: [String] = ["当前状态："]
            lines.append("· 游戏窗口（异环/NTE）：\(Self.boolText(gameVisible))")
            lines.append("· 辅助功能权限：\(Self.boolText(trusted))（未授权时一切注入会被系统丢弃）")
            lines.append("· 观测模式：\(Self.boolText(observeOnly))（开启时一切注入类工具被拒绝）")
            lines.append("· 运行中技能：\(running.isEmpty ? "无" : running.joined(separator: "、"))")
            lines.append("· 最近用户任务：\(String(lastUser.prefix(60)))")
            lines.append("· 模型：\(settings.backendKind.rawValue) · \(settings.model)"
                         + "（视觉开关=\(Self.boolText(settings.visionEnabled))，"
                         + "API Key=\(Self.boolText(!settings.apiKey.isEmpty))）")
            lines.append("· 按键引擎：技能中心=\(Self.boolText(center.controlEngineAvailable()))"
                         + "／注册表显式接入 control=\(Self.boolText(attachedControlSnapshot != nil))"
                         + " capture=\(Self.boolText(attachedCaptureSnapshot != nil))")
            if let control = attachedControlSnapshot {
                lines.append("· 累计注入事件（按键引擎）：\(control.postedEventCount)；按住的键：\(control.heldCount) 个")
            }
            if let events = mouseEvents {
                lines.append("· 累计注入事件（鼠标）：\(events)")
            }
            lines.append("· 已注册工具：\(toolNames.count) 个")
            return lines.joined(separator: "\n")
        }

        var text = report
        text += "\n\n[工具清单]\n" + toolNames.joined(separator: "、")
        if dryRun {
            text += "\n\n（干跑：本次为只读状态查询，未执行任何副作用动作）"
        }
        // 如实回填 dryRun —— 硬编码 false 会谎报「真读了状态」，让 W8 的干跑断言失去意义
        return .success("get_status", text, dryRun: dryRun)
    }

    // MARK: - 搜索工具（实现归 W5 WebSearch.swift；本文件只做参数校验与格式化）

    private func webSearch(args: [String: String], dryRun: Bool) async throws -> ToolResult {
        let query = try requiredString(args, "query")
        let maxResults = try optionalInt(args, "maxResults", default: 5, range: 1...20) ?? 5
        if dryRun {
            return .success("web_search", "干跑：将联网搜索「\(query)」（最多 \(maxResults) 条，未发起请求）", dryRun: true)
        }
        do {
            let results = try await WebSearch.shared.search(query: query, maxResults: maxResults)
            guard !results.isEmpty else {
                return .failure("web_search", "搜索「\(query)」未返回任何结果（如实回报，不编造）", dryRun: false)
            }
            var lines: [String] = ["搜索「\(query)」得到 \(results.count) 条结果："]
            for (index, item) in results.enumerated() {
                let snippet = item.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("\(index + 1). \(item.title)\n   \(item.url)\n   \(String(snippet.prefix(300)))")
            }
            var body = lines.joined(separator: "\n")
            if body.count > 4000 { body = String(body.prefix(4000)) + "\n…（已截断）" }
            return .success("web_search", body, dryRun: false)
        } catch {
            return .failure("web_search", "搜索失败（如实回报，不编造）：\(Self.describe(error))", dryRun: false)
        }
    }

    private func webFetch(args: [String: String], dryRun: Bool) async throws -> ToolResult {
        let url = try requiredString(args, "url")
        let maxCharacters = try optionalInt(args, "maxCharacters", default: 8000, range: 500...20000) ?? 8000
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ToolFailure(message: "url 必须是 http/https 开头的完整网址，收到：\(url)")
        }
        if dryRun {
            return .success("web_fetch", "干跑：将抓取 \(url) 正文（最多 \(maxCharacters) 字符，未发起请求）", dryRun: true)
        }
        do {
            let body = try await WebSearch.shared.fetch(url: url, maxCharacters: maxCharacters)
            guard !body.isEmpty else {
                return .failure("web_fetch", "页面正文为空（如实回报，不编造）：\(url)", dryRun: false)
            }
            return .success("web_fetch", "已抓取 \(url)（\(body.count) 字符）：\n\n\(body)", dryRun: false)
        } catch {
            return .failure("web_fetch", "抓取失败（如实回报，不编造）：\(Self.describe(error))", dryRun: false)
        }
    }

    // MARK: - 引擎解析

    /// 解析 ControlEngine：显式 attach 优先，否则回退 `DriveState.shared`
    private func resolveControl() async -> ControlEngine? {
        if let attachedControl { return attachedControl }
        return await MainActor.run { DriveState.shared.controlEngine }
    }

    /// 必须拿到控制引擎，否则抛出明确原因（不静默）
    private func requireControl() async throws -> ControlEngine {
        guard let control = await resolveControl() else {
            throw ToolFailure(message: Self.noControlEngineText)
        }
        return control
    }

    /// 解析当前帧：显式接入的采集引擎优先，否则回退 `DriveState.shared`
    private func currentFrameCG() async -> CGImage? {
        let capture = attachedCapture
        return await MainActor.run {
            if let capture, let image = capture.currentFrame {
                return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            if let cg = DriveState.shared.currentFrameCG { return cg }
            if let image = DriveState.shared.captureEngine.currentFrame {
                return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            return nil
        }
    }

    /// 复用同一个 MouseController，保证 postedEventCount 连续（差值才有意义）
    private func mouseController() -> MouseController {
        if let mouse { return mouse }
        let controller = MouseController()
        mouse = controller
        return controller
    }

    /// 当前累计注入事件数（按键引擎 + 鼠标引擎）
    private func currentEventTotal() async -> Int {
        let control = await resolveControl()
        return (control?.postedEventCount ?? 0) + (mouse?.postedEventCount ?? 0)
    }

    // MARK: - 参数解析

    private func requiredString(_ args: [String: String], _ key: String) throws -> String {
        guard let raw = args[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw ToolFailure(message: "缺少必需参数 \(key)")
        }
        return raw
    }

    private func optionalDouble(_ args: [String: String], _ key: String,
                                default def: Double, range: ClosedRange<Double>) throws -> Double {
        guard let raw = args[key], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return def }
        guard let value = Double(raw) else {
            throw ToolFailure(message: "参数 \(key) 必须是数字，收到「\(raw)」")
        }
        guard range.contains(value) else {
            throw ToolFailure(message: "参数 \(key)=\(value) 超出允许范围 \(Self.format(range.lowerBound))–\(Self.format(range.upperBound))")
        }
        return value
    }

    private func optionalInt(_ args: [String: String], _ key: String,
                             default def: Int?, range: ClosedRange<Int>) throws -> Int? {
        guard let raw = args[key], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return def }
        // 必须是整数：先按 Double 解析再校验「是否为整数值」，**不静默截断**
        // （1.5 → 1 这种猜测会掩盖模型给的坏参数，宁可明确报错让它自我修正）
        guard let value = Double(raw) else {
            throw ToolFailure(message: "参数 \(key) 必须是整数，收到「\(raw)」")
        }
        guard value == value.rounded() else {
            throw ToolFailure(message: "参数 \(key) 必须是整数，收到「\(raw)」（不接受小数）")
        }
        let intValue = Int(value)
        guard range.contains(intValue) else {
            throw ToolFailure(message: "参数 \(key)=\(intValue) 超出允许范围 \(range.lowerBound)–\(range.upperBound)")
        }
        return intValue
    }

    private func pointArgs(_ args: [String: String]) throws -> CGPoint {
        let x = try requiredDouble(args, "x")
        let y = try requiredDouble(args, "y")
        guard (0...100_000).contains(x), (0...100_000).contains(y) else {
            throw ToolFailure(message: "坐标超出合理范围：x=\(Self.format(x)), y=\(Self.format(y))")
        }
        return CGPoint(x: x, y: y)
    }

    private func requiredDouble(_ args: [String: String], _ key: String) throws -> Double {
        guard let raw = args[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw ToolFailure(message: "缺少必需参数 \(key)")
        }
        guard let value = Double(raw) else {
            throw ToolFailure(message: "参数 \(key) 必须是数字，收到「\(raw)」")
        }
        return value
    }

    /// 键名 → GameKey（大小写不敏感；接受少量常见别名，键表本身不另建）
    private func resolveGameKey(_ raw: String) throws -> ControlEngine.GameKey {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hit = Self.gameKeyAliases[key] { return hit }
        throw ToolFailure(message: "不支持的按键「\(raw)」。可用键：\(Self.gameKeyListText)")
    }

    // MARK: - 静态表

    private static let noControlEngineText =
        "按键引擎未接入（AgentSkillCenter 尚未 configure 且 DriveState 未就绪），无法注入，本次未发送任何事件"

    /// 无参工具的 schema
    private static let noArgSchema: String = schemaJSON(properties: [:], required: [])

    /// 构造 object 根 schema 的序列化串（失败回退 "{}"，由 registerAll 自检报出）
    private static func schemaJSON(properties: [String: Any], required: [String]) -> String {
        let dict: [String: Any] = [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false,
        ]
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// `ControlEngine.GameKey` 的全部取值 —— 唯一键位真相源：不另建键表
    private static var gameKeyNames: [String] {
        ControlEngine.GameKey.allCases.map(\.rawValue)
    }

    private static var gameKeyListText: String {
        gameKeyNames.joined(separator: "/")
    }

    /// 键名 → GameKey（含少量输入容错别名；别名只映射到真实存在的 key）
    private static var gameKeyAliases: [String: ControlEngine.GameKey] {
        var map: [String: ControlEngine.GameKey] = [:]
        for key in ControlEngine.GameKey.allCases {
            map[key.rawValue.lowercased()] = key
        }
        map["escape"] = .esc
        map["spacebar"] = .space
        map["空格"] = .space
        map["control"] = .ctrl
        map["leftshift"] = .shift
        map["rightctrl"] = .ctrl
        return map
    }

    /// 技能工具描述（取自 `execute()` 各 case 的实际行为注释 + 库里的关键词/风险标记）
    private static func skillToolDescription(_ skill: AgentSkill) -> String {
        let behavior: String
        switch skill.id {
        case "auto_login":      behavior = "全屏 OCR 定位登录按钮并点击；游戏未启动到登录界面时进入 80 秒守护等待"
        case "volleyball":      behavior = "排球小游戏自动按键循环"
        case "fishing":         behavior = "F 抛竿 → 等收杆节奏 → 循环"
        case "coffee":          behavior = "F 键交互 ×20 轮做咖啡"
        case "coffee_lite":     behavior = "F 键交互 ×10 轮（轻量做咖啡）"
        case "bagel_spam":      behavior = "游戏聊天框内输入内置文案刷屏（需先让聊天框获得焦点）"
        case "pinkpaw":         behavior = "粉爪大劫案流程"
        case "furniture":       behavior = "OCR 定位「收取」按钮并循环点击，直到没有可收家具"
        case "rewards":         behavior = "OCR 定位「领取」按钮并循环点击领取奖励"
        case "piano":           behavior = "内置「小星星」旋律，G/H/I 音键循环"
        case "rhythm":          behavior = "超强音 / 音游节奏自动按键"
        case "dodge":           behavior = "持续闪避按键循环，躲避追踪弹/红圈"
        case "auto_scroll":     behavior = "周期性 F 连点 + 滚轮（拾取/翻页）"
        case "touch":           behavior = "F 交互 → 点击抚摸区 → ESC 退出"
        case "drive_dataset":   behavior = "2Hz 采样 W/A/S/D 写入驾驶数据集"
        case "preset_afk":      behavior = "一键依次启动 领奖励 → 收家具 → 钓鱼 的挂机组合"
        case "preset_realtime": behavior = "实时辅助预设"
        case "tomato_juice":    behavior = "自动制作番茄汁流程"
        default:                behavior = "游戏内自动化流程"
        }
        var text = "启动游戏技能「\(skill.name)」：\(behavior)。"
        if !skill.keywords.isEmpty {
            text += "（人类通常说：\(skill.keywords.joined(separator: "、"))）"
        }
        if skill.warn {
            text += " ⚠️ 高危技能，建议先向用户确认再调用。"
        }
        if !skill.ported {
            text += " ⚠️ 该技能在当前代码库中标记为未移植，调用会返回失败，不要反复尝试。"
        }
        return text
    }

    // MARK: - 小工具

    private func insert(_ tool: AgentTool) {
        guard tools[tool.name] == nil else {
            registrationErrors.append("工具名重复注册：\(tool.name)")
            return
        }
        tools[tool.name] = tool
        order.append(tool.name)
    }

    /// 数字格式化（整数不带小数点）
    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static func boolText(_ value: Bool) -> String {
        value ? "是" : "否"
    }

    private static func describe(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return "\(error)"
    }

    /// 截图输出路径（工具结果只带路径；画面是否发给模型由面板视觉开关决定）
    private static func screenshotOutputURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("aurora_tool_screenshot.jpg")
    }

    /// 编码为 JPEG：长边 ≤1568px、质量 0.8
    ///
    /// 门限与 W2 的图片编码硬门限一致（实测 762KB base64 可用；原图直出约 8MB 会超限）。
    private static func encodeJPEG(_ image: CGImage,
                                   maxDimension: CGFloat = 1568,
                                   quality: CGFloat = 0.8) -> (data: Data, width: Int, height: Int)? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxDimension / max(width, height))
        let targetWidth = max(1, Int((width * scale).rounded()))
        let targetHeight = max(1, Int((height * scale).rounded()))

        guard let context = CGContext(data: nil,
                                      width: targetWidth,
                                      height: targetHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = context.makeImage() else { return nil }

        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            return nil
        }
        return (data, targetWidth, targetHeight)
    }
}
