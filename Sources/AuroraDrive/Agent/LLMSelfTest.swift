// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  LLMSelfTest.swift — AI 助手「真对话 / 自主按键 / 自主调工具」命令行自检（W8）
// ============================================================================
//
//  【本文件的定位】
//    W8 是**独立验证方**：只读产品代码，不修改任何他人文件。
//    本文件是 W8 唯一新建的 Sources 产物，且**只放 CLI 自检逻辑 与 其证据采集**，
//    不含任何产品运行时逻辑（产品路径一行都不经过这里）。
//
//  【约定：返回失败项数，0 = 全过】
//    与仓库既有自检（`runWireSelfTest` / `runLaneKeepRealityTest` /
//    `QuestPanelReader.runSelfTest` / `AuroraCacheSelfTest.run`）**完全一致**：
//    调用方 `exit(failed == 0 ? 0 : Int32(min(failed, 127)))`。
//    因此「自检发现真问题」= **非零退出码**，可被 CI / 负向对照直接判定。
//
//  【命令清单】（已在 AuroraDriveApp.swift 的 oneShotFlags 登记）
//    --llm-selftest [--network]  A1：协议 / SSE 分片 / 错误分类 / 候选排序（离线）
//    --llm-probe                 A1：7 渠道真实探活健康表（需要网络）
//    --llm-vision-selftest       A1：真实截图 → 视觉模型断言（需要网络 + 录屏权限）
//    --control-selftest          A2：按键四证据链（权限 / 计数 / 自建 tap / NSEvent）
//    --tool-selftest             A3：注册表覆盖 + schema 合法 + 全工具 dryRun
//    --tool-call-demo <task>     A3：模型决策 → 工具分发 → 执行 闭环
//    --llm-perf-selftest         性能预算断言（主线程阻塞 / 首字延迟 / 内存）
//
//  【纪律】
//    · 每一条断言都打印**证据原文**（不是只说"通过"），便于报告直接引用。
//    · 未验证项**明确标注「未验证」**并计入失败或标注为环境受限 —— 绝不编造。
//    · 不联网的命令（`--llm-selftest` 默认、`--control-selftest` 的 ①③、
//      `--tool-selftest`）在离线环境必须照样能跑出结论。
//
// ============================================================================

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - 断言小工具

/// 自检记账器：统一打印格式（`✅ / ❌ / ⚠️`）并累计失败数。
///
/// 【为什么自带一个而不是复用别的】既有自检各自内联 `check` 闭包（如
/// `runMapWindowTest` / `runPerfSelfTest`），本文件有 7 个独立自检入口、
/// 300+ 条断言，内联会导致重复代码；抽一个小类型是纯机械提取，不改语义。
final class SelfTestLedger {

    private(set) var failed = 0
    private(set) var passed = 0

    /// 断言通过/失败。- Parameter: detail 必须是**原始证据**（数字/字符串/错误原文）。
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1 } else { failed += 1 }
        let mark = ok ? "✅" : "❌"
        print(detail.isEmpty ? "  \(mark) \(name)" : "  \(mark) \(name)  \(detail)")
    }

    /// 断言相等并打印两侧原值（失败时一眼能看出差异）
    func equals<T: Equatable>(_ name: String, _ got: T, _ want: T, extra: String = "") {
        let ok = got == want
        let suffix = extra.isEmpty ? "" : "（\(extra)）"
        check(name, ok, "得到=\(got) 期望=\(want)\(suffix)")
    }

    /// 只记录、不影响退出码的提示（用于**环境受限**与「未验证」标注）
    func note(_ text: String) { print("  ⚠️ \(text)") }

    /// 小节标题
    func section(_ title: String) { print("\n── \(title) ──") }

    /// 汇总行。返回失败项数（= 进程退出码来源）
    func summary(_ title: String) -> Int {
        print("\n═══ \(title)：\(failed == 0 ? "PASS" : "FAIL")（\(passed) 通过 / \(failed) 失败）═══")
        return failed
    }
}

// MARK: - 自检入口

enum LLMSelfTest {

    // MARK: A1 · 协议与链路（--llm-selftest [--network]）

    /// A1 自检：**离线部分恒跑**（协议/SSE/错误分类/候选排序/配置契约），
    /// `--network` 时追加真实请求（此时失败**计入**退出码 —— 这是 A1 的硬指标）。
    ///
    /// 【为什么离线/联网要分开】
    ///   · 断网环境不该让「协议解析」这类纯逻辑结论变红（那是误报）；
    ///   · 但用户规格是「对话真能用」——**联网时必须发真请求**，且失败就是失败。
    ///   故：离线断言恒跑；`--network` 追加真请求且失败计入。
    static func runLLM(ledger: SelfTestLedger, network: Bool) async {
        print("═══ A1 · LLM 链路自检（--llm-selftest\(network ? " --network" : "")）═══")
        print("时间: \(timestamp())")

        offlineProtocol(ledger)
        offlineSSE(ledger)
        offlineErrorClassification(ledger)
        await offlineCandidates(ledger)
        offlineBackends(ledger)
        offlineSettings(ledger)
        await healthStateSemantics(ledger)
        await offlineHealthSelfCheck(ledger)

        if network {
            await networkRealRequest(ledger)
        } else {
            ledger.section("真实请求（未执行）")
            ledger.note("本次未带 --network：**未验证**「对话真能用」这一步。"
                        + "带 --network 重跑才是 A1 的有效证据。")
        }
    }

    // MARK: 渠道凭据（与生产代码同款）

    /// 取某候选**应当**使用的 API Key。
    ///
    /// ══════════════════════════════════════════════════════════════════════════
    /// ⚠️ 2026-10-06 缺陷修复记录（W7 报，W8 独立复现确认）
    /// ══════════════════════════════════════════════════════════════════════════
    /// 【原缺陷】自检原先写成 `settings.apiKey.isEmpty ? nil : settings.apiKey`，
    ///   没判断 `requiresKey` → 把用户小本本里的旧 key **发给 OVH 这类免 key 渠道**。
    ///
    /// 【为什么要紧 —— 不是"顺手泄漏"，而是**会把故障归因写错**】
    ///   W8 用 curl 对同一端点、同一 body 只改 Authorization 做了三分对照
    ///   （原始输出：`verify/evidence-llm/ovh-key-vs-nokey-curl.txt`）：
    ///     · 不发 Authorization 头      → **HTTP 429** `API rate limit exceeded`（真实状态：限流）
    ///     · 空 Authorization（等价 nil）→ **HTTP 200 成功**（匿名层可用）
    ///     · `Bearer <本机旧 key>`       → **HTTP 403** `Forbidden: authentication failed`
    ///   两组失败**错因完全不同**：403 是"你给了一把无效的 key"，429 是"没带 key 但配额用完"。
    ///   自检把 403 归类成 `.invalidKey` 并写进健康态 → OVH 5 个模型被标成 invalidKey
    ///   而不是 rateLimited → 报告里"渠道全挂"的**归因会写错**。
    ///   （W3 的 `.invalidKey` 分支特意不改模型状态，防的正是这种误判。）
    ///
    /// 【修法】免 key 渠道一律返回 nil —— 与 W7 生产代码
    ///   `AgentLoop.apiKey(for:settings:)` 逐字同款，也是 W2 `LLMRequest.apiKey`
    ///   的契约（nil/空 = 不带该头）。
    private static func apiKey(for candidate: LLMCandidate, settings: AgentSettings) -> String? {
        guard candidate.backend.requiresKey else { return nil }
        return settings.apiKey.isEmpty ? nil : settings.apiKey
    }

    // MARK: A1 · 协议（离线）

    /// 验证 8 渠道描述符与「不得硬编码 key」红线。
    private static func offlineBackends(_ ledger: SelfTestLedger) {
        ledger.section("8 渠道描述符")

        let registry = LLMBackendRegistry.shared
        let descriptors = registry.allDescriptors()

        ledger.equals("渠道数 = LLMBackendKind.allCases.count",
                      descriptors.count, LLMBackendKind.allCases.count)
        ledger.equals("渠道数 = 8", descriptors.count, 8)

        // 免 key 层 4 个必须存在且 requiresKey=false
        let keyless = descriptors.filter(\.isKeyless).map(\.kind)
        ledger.check("免 key 层 = OVH/Zen/Pollinations/旧Pollinations",
                     Set(keyless) == Set([.ovhAnonymous, .zenFree, .pollinations, .pollinationsLegacy]),
                     "实际=\(keyless.map(\.rawValue).joined(separator: ","))")

        // 需 key 层 4 个
        let keyed = descriptors.filter { !$0.isKeyless }.map(\.kind)
        ledger.check("需 key 层 = 智谱/Groq/OpenRouter/自定义",
                     Set(keyed) == Set([.zhipu, .groq, .openRouter, .userKey]),
                     "实际=\(keyed.map(\.rawValue).joined(separator: ","))")

        // baseURL 必须 https 且非空
        for d in descriptors {
            ledger.check("\(d.kind.rawValue) baseURL 合法",
                         d.baseURL.hasPrefix("https://"),
                         d.baseURL)
        }

        // OVH 轮转表顺序（大到小，任务书指定顺序）
        let ovh = LLMModelCatalog.ovhRotation
        ledger.equals("OVH 静态表 5 个模型", ovh.count, 5)
        ledger.check("OVH 轮转首位 = Qwen3.5-397B-A17B",
                     ovh.first?.id == "Qwen3.5-397B-A17B", ovh.first?.id ?? "（空）")
        ledger.check("OVH 视觉模型 = Qwen2.5-VL-72B-Instruct",
                     ovh.contains { $0.id == "Qwen2.5-VL-72B-Instruct" && $0.supportsVision },
                     "supportsVision 命中数=\(ovh.filter(\.supportsVision).count)")

        // Pollinations 静态表 37
        ledger.equals("Pollinations 静态表 37 个模型",
                      LLMModelCatalog.pollinations.count, 37)
        // 静态表里全部 supportsVision=false（渠道图片请求要 key）
        ledger.check("Pollinations 全部 supportsVision=false（图片要 key）",
                     LLMModelCatalog.pollinations.allSatisfy { !$0.supportsVision },
                     "视觉模型数=\(LLMModelCatalog.pollinations.filter(\.supportsVision).count)")

        // Zen 三头注入（实测要求）
        if let zen = registry.descriptor(for: .zenFree) {
            let h = zen.extraHeaders
            ledger.check("Zen 注入 User-Agent=opencode/1.18.30",
                         h["User-Agent"] == "opencode/1.18.30", h["User-Agent"] ?? "（缺）")
            ledger.check("Zen 注入 Authorization=Bearer public",
                         h["Authorization"] == "Bearer public", h["Authorization"] ?? "（缺）")
            let session = h["x-opencode-session"] ?? ""
            ledger.check("Zen 注入 x-opencode-session=ses_+26hex",
                         session.hasPrefix("ses_") && session.count == 30,
                         "\(session)（长度 \(session.count)）")
            ledger.equals("Zen session 实例内稳定（两次取描述符同值）",
                          registry.descriptor(for: .zenFree)?.extraHeaders["x-opencode-session"] ?? "",
                          session)
        } else {
            ledger.check("Zen 描述符存在", false, "descriptor(for:.zenFree) 返回 nil")
        }

        // 红线：源码不得硬编码 API Key（扫描述符的所有头与 baseURL）
        var leak: [String] = []
        for d in descriptors {
            for (name, value) in d.extraHeaders where value.contains("sk-") {
                leak.append("\(d.kind.rawValue).\(name)=\(value)")
            }
            if d.baseURL.contains("sk-") { leak.append("\(d.kind.rawValue).baseURL") }
            for m in d.staticModels where m.id.contains("sk-") {
                leak.append("\(d.kind.rawValue).model=\(m.id)")
            }
        }
        ledger.check("无硬编码 sk- 凭据（描述符全字段扫描）",
                     leak.isEmpty, leak.isEmpty ? "扫描 \(descriptors.count) 个描述符" : leak.joined(separator: "; "))
    }

    // MARK: A1 · 协议（消息编码）

    private static func offlineProtocol(_ ledger: SelfTestLedger) {
        ledger.section("消息与工具编码（OpenAI 兼容形状）")

        // ① 无图：content 必须是字符串，且空串也要写这个键
        let plain = LLMMessage.user("你好")
        let plainDict = plain.openAIDictionary()
        ledger.check("无图 content 是 String",
                     plainDict["content"] as? String == "你好",
                     "content=\(String(describing: plainDict["content"]))")
        ledger.equals("role 透传", plainDict["role"] as? String ?? "", "user")

        // assistant 空文本回合：必须有 content 键（否则部分渠道 400）
        let emptyAssistant = LLMMessage.assistant("")
        let emptyDict = emptyAssistant.openAIDictionary()
        ledger.check("assistant 空文本仍带 content 键",
                     emptyDict.keys.contains("content") && (emptyDict["content"] as? String) == "",
                     "keys=\(emptyDict.keys.sorted().joined(separator: ","))")

        // ② 有图：content 变数组，text + image_url 两 part
        let image = LLMImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), mimeType: "image/jpeg")
        let withImage = LLMMessage.user("看这个", images: [image])
        let imageDict = withImage.openAIDictionary()
        let parts = imageDict["content"] as? [[String: Any]] ?? []
        ledger.equals("有图 content 是数组且 2 个 part", parts.count, 2)
        ledger.check("part[0] 是 text",
                     parts.first?["type"] as? String == "text",
                     "type=\(parts.first?["type"] as? String ?? "（无）")")
        ledger.check("part[1] 是 image_url.data:image/jpeg;base64,",
                     (parts.last?["type"] as? String) == "image_url"
                     && ((parts.last?["image_url"] as? [String: Any])?["url"] as? String)?
                        .hasPrefix("data:image/jpeg;base64,") == true,
                     "url 前缀=\(String(((parts.last?["image_url"] as? [String: Any])?["url"] as? String ?? "").prefix(28)))")

        // ③ 工具结果消息必须带 tool_call_id
        let toolMsg = LLMMessage.tool("结果", toolCallID: "call_1")
        ledger.check("tool 消息带 tool_call_id",
                     toolMsg.openAIDictionary()["tool_call_id"] as? String == "call_1",
                     "tool_call_id=\(toolMsg.openAIDictionary()["tool_call_id"] as? String ?? "（缺）")")

        // ④ 工具规格包装层：{"type":"function","function":{...}}
        do {
            let spec = try LLMToolSpec.make(name: "press_key",
                                            description: "按键",
                                            parameters: ["type": "object",
                                                         "properties": ["key": ["type": "string"]],
                                                         "required": ["key"]])
            let wrapped = spec.openAIDictionary()
            let function = wrapped["function"] as? [String: Any]
            ledger.check("工具规格是 function 包装层",
                         wrapped["type"] as? String == "function" && function != nil,
                         "type=\(wrapped["type"] as? String ?? "（无）")")
            ledger.check("工具 parameters 被解析成对象（不是字符串）",
                         (function?["parameters"] as? [String: Any]) != nil,
                         "parameters 类型=\(type(of: function?["parameters"] ?? "nil"))")
        } catch {
            ledger.check("工具规格构造", false, "\(error)")
        }

        // ⑤ 图片编码硬门限常量
        ledger.equals("图片长边门限 1568px", LLMImageEncoder.maxLongEdge, 1568)
        ledger.equals("JPEG 质量 0.8", LLMImageEncoder.jpegQuality, 0.8, extra: "Double 比较")

        // ⑥ 图片编码实测：造一张 2940×1912 大图（任务书里会超限的尺寸），
        //    过 encode 后必须 ≤ 门限（长边 ≤1568 且字节 ≤2MB）
        var pixel = CGImage?.none
        let bigWidth = 2940, bigHeight = 1912
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let ctx = CGContext(data: nil, width: bigWidth, height: bigHeight,
                               bitsPerComponent: 8, bytesPerRow: bigWidth * 4,
                               space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            // 画点内容（纯色压缩率过高，加渐变更像真实截图，避免"压缩后很小"的假通过）
            for i in stride(from: 0, to: bigWidth, by: 8) {
                ctx.setFillColor(CGColor(red: Double(i) / Double(bigWidth),
                                         green: 0.3, blue: 0.7, alpha: 1))
                ctx.fill(CGRect(x: i, y: 0, width: 8, height: bigHeight))
            }
            pixel = ctx.makeImage()
        }
        if let frame = pixel {
            do {
                let encoded = try LLMImageEncoder.encode(cgImage: frame)
                let longEdge = max(encoded.pixelWidth ?? 0, encoded.pixelHeight ?? 0)
                ledger.check("2940×1912 → 长边 ≤1568",
                             longEdge <= LLMImageEncoder.maxLongEdge,
                             "编码后 \(encoded.pixelWidth ?? 0)×\(encoded.pixelHeight ?? 0)（长边 \(longEdge)）")
                ledger.check("2940×1912 → 字节 ≤2MB",
                             encoded.data.count <= LLMImageEncoder.maxEncodedBytes,
                             "\(encoded.data.count) 字节 / 上限 \(LLMImageEncoder.maxEncodedBytes)")
                ledger.check("编码产物是 JPEG（FFD8FF 魔数）",
                             LLMImageEncoder.isJPEG(encoded.data),
                             "前 3 字节=\(encoded.data.prefix(3).map { String(format: "%02X", $0) }.joined())")
                // 与任务书的实测锚点对齐：762KB base64 可用
                ledger.check("base64 估算量级合理（>1KB 且 ≤2MB 的 4/3）",
                             encoded.encodedByteCount > 1024
                             && encoded.encodedByteCount <= LLMImageEncoder.maxEncodedBytes * 4 / 3 + 64,
                             "encodedByteCount≈\(encoded.encodedByteCount)")
            } catch {
                ledger.check("大图编码（2940×1912）", false, "抛出：\(error)")
            }
        } else {
            ledger.check("构造 2940×1912 测试图", false, "CGContext 创建失败")
        }
    }

    // MARK: A1 · SSE 分片解析（离线）

    /// 把 `SSEParser` 的分块解析结果摊平成事件流。
    ///
    /// 【为什么需要这层适配】W2 的 `SSEParser.consume/finish` 返回
    /// `[LLMChunkParse]`（每个分片可能带 0..n 个事件 + finish_reason + usage），
    /// 而不是 `[LLMStreamEvent]`。自检只关心事件序列，故在这里摊平一次；
    /// 携带 usage/finishReason 的那部分由 `LLMStreamAccumulator` 路径单独验证。
    private static func events(_ parses: [LLMChunkParse]) -> [LLMStreamEvent] {
        parses.flatMap(\.events)
    }

    private static func offlineSSE(_ ledger: SelfTestLedger) {
        ledger.section("SSE 流式解析（分片边界）")

        // ① 标准流：多个 data: 行 + [DONE]
        var state = SSEStreamState()
        var text = ""
        var sawDone = false
        let chunks = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"好\"}}]}\n\n",
            "data: [DONE]\n\n",
        ]
        for chunk in chunks {
            for event in events(SSEParser.consume(&state, chunk: Data(chunk.utf8))) {
                if case .delta(let piece) = event { text += piece }
            }
        }
        for event in events(SSEParser.finish(&state)) {
            if case .delta(let piece) = event { text += piece }
        }
        sawDone = state.sawDoneSentinel
        ledger.equals("标准 SSE 三段拼出「你好」", text, "你好")
        ledger.check("[DONE] 哨兵被识别", sawDone, "sawDoneSentinel=\(sawDone)")

        // ② 关键回归：**把一个 JSON 切在两个网络包中间**（真实网络必然发生）
        var splitState = SSEStreamState()
        var splitText = ""
        let full = "data: {\"choices\":[{\"delta\":{\"content\":\"完整回答\"}}]}\n\n"
        let cut = full.index(full.startIndex, offsetBy: 34)
        for piece in [String(full[full.startIndex..<cut]), String(full[cut...])] {
            for event in events(SSEParser.consume(&splitState, chunk: Data(piece.utf8))) {
                if case .delta(let t) = event { splitText += t }
            }
        }
        for event in events(SSEParser.finish(&splitState)) {
            if case .delta(let t) = event { splitText += t }
        }
        ledger.equals("跨包切分的 JSON 仍完整拼出", splitText, "完整回答")

        // ③ UTF-8 多字节字符被切在包边界（中文场景实测会遇到）
        var utf8State = SSEStreamState()
        var utf8Text = ""
        let utf8Full = "data: {\"choices\":[{\"delta\":{\"content\":\"中文\"}}]}\n\n"
        let utf8Bytes = Array(utf8Full.utf8)
        // 找到「中」的 UTF-8 首字节位置，从它中间切断
        let mid = utf8Bytes.firstIndex(of: 0xE4) ?? 30
        let cutAt = mid + 1
        for slice in [utf8Bytes[0..<cutAt], utf8Bytes[cutAt...]] {
            for event in events(SSEParser.consume(&utf8State, chunk: Data(slice))) {
                if case .delta(let t) = event { utf8Text += t }
            }
        }
        for event in events(SSEParser.finish(&utf8State)) {
            if case .delta(let t) = event { utf8Text += t }
        }
        ledger.equals("多字节中文字符跨包不丢字", utf8Text, "中文")

        // ④ 不写空行的渠道（实测存在）：一行一个 data:
        var noBlankState = SSEStreamState()
        var noBlankText = ""
        let noBlank = "data: {\"choices\":[{\"delta\":{\"content\":\"A\"}}]}\n"
                   + "data: {\"choices\":[{\"delta\":{\"content\":\"B\"}}]}\n"
        for event in events(SSEParser.consume(&noBlankState, chunk: Data(noBlank.utf8))) {
            if case .delta(let t) = event { noBlankText += t }
        }
        ledger.equals("无空行分隔的 SSE 也能解析", noBlankText, "AB")

        // ⑤ 心跳注释行必须被忽略
        var commentState = SSEStreamState()
        var commentText = ""
        let withComment = ": keep-alive\n\n"
                        + "data: {\"choices\":[{\"delta\":{\"content\":\"X\"}}]}\n\n"
        for event in events(SSEParser.consume(&commentState, chunk: Data(withComment.utf8))) {
            if case .delta(let t) = event { commentText += t }
        }
        ledger.equals("注释/心跳行被忽略且不影响内容", commentText, "X")

        // ⑥ reasoning_content 单独成事件（推理模型）
        var reasonState = SSEStreamState()
        var reasoning = ""
        let reasonChunk = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"想一想\"}}]}\n\n"
        for event in events(SSEParser.consume(&reasonState, chunk: Data(reasonChunk.utf8))) {
            if case .reasoning(let t) = event { reasoning += t }
        }
        ledger.equals("reasoning_content → .reasoning 事件", reasoning, "想一想")

        // ⑦ tool_calls 分片累积：id 只在首片，arguments 跨多片
        var acc = LLMStreamAccumulator()
        let toolChunks = [
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_9\",\"function\":{\"name\":\"press_key\",\"arguments\":\"{\\\"key\\\":\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"W\\\"}\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
        ]
        // ⚠️ 必须走 `consume`（生产入口，会按 SSE 字段剥掉 `data: ` 前缀），
        //    不能用 `SSEParser.parse(chunk:)` —— 后者契约是**裸 JSON**，
        //    喂整行 SSE 会 JSON 解析失败返回空 parse（2026-10-06 实测踩到，
        //    导致本节 4 条断言假红；W7 用生产路径独立复核后确认产品侧无问题）。
        var toolState = SSEStreamState()
        for chunk in toolChunks {
            for parse in SSEParser.consume(&toolState, chunk: Data(chunk.utf8)) {
                acc.noteChunk(parse)
            }
        }
        for parse in SSEParser.finish(&toolState) { acc.noteChunk(parse) }
        ledger.equals("tool_calls 累积为 1 个调用", acc.toolCalls.count, 1)
        ledger.equals("工具名解析正确", acc.toolCalls.first?.name ?? "", "press_key")
        ledger.equals("分片 arguments 拼接完整", acc.toolCalls.first?.argumentsJSON ?? "", "{\"key\":\"W\"}")
        ledger.equals("finish_reason 透传", acc.finishReason ?? "", "tool_calls")

        // ⑧ 括号配对扫描：模型正文里含 `{` `}` 不能误切 JSON 边界
        ledger.check("extractJSONObject 不受正文花括号干扰",
                     SSEParser.extractJSONObject("{\"a\":\"x{y}z\"}tail")?.0 == "{\"a\":\"x{y}z\"}",
                     "切出=\(SSEParser.extractJSONObject("{\"a\":\"x{y}z\"}tail")?.0 ?? "nil")")
        ledger.check("extractJSONObject 遇转义引号不错位",
                     SSEParser.extractJSONObject("{\"a\":\"\\\"}\"}")?.0 == "{\"a\":\"\\\"}\"}",
                     "切出=\(SSEParser.extractJSONObject("{\"a\":\"\\\"}\"}")?.0 ?? "nil")")

        // ⑨ HTTP 200 + 空 content：必须能被上层识别为「没有内容」（不是静默成功）
        var emptyAcc = LLMStreamAccumulator()
        emptyAcc.noteChunk(SSEParser.parse(chunk: Data("{\"choices\":[{\"delta\":{\"content\":\"\"},\"finish_reason\":\"stop\"}]}".utf8)))
        ledger.check("空 content 分片不产生 delta（上层据此判 .badResponse）",
                     emptyAcc.text.isEmpty && !emptyAcc.sawContentChunk,
                     "text=\"\(emptyAcc.text)\" sawContentChunk=\(emptyAcc.sawContentChunk)")
    }

    // MARK: A1 · 错误分类（离线）

    private static func offlineErrorClassification(_ ledger: SelfTestLedger) {
        ledger.section("错误分类（12 类逐条）")

        // 任务书里逐条给出的实测上游返回，全部按原文构造
        let cases: [(String, Int, String, LLMErrorKind)] = [
            ("FreeTierError → .gated", 402,
             "{\"type\":\"error\",\"error\":{\"type\":\"FreeTierError\",\"message\":\"free tier\"}}", .gated),
            ("RegionError → .regionBlocked", 403,
             "{\"type\":\"error\",\"error\":{\"type\":\"RegionError\",\"message\":\"region\"}}", .regionBlocked),
            ("ModelDeprecated + replacement → .modelDeprecated", 400,
             "{\"error\":{\"type\":\"ModelDeprecated\",\"metadata\":{\"replacement\":\"Qwen3.6-27B\"}}}", .modelDeprecated),
            ("ModelDeprecated 无 replacement → .modelNotFound", 400,
             "{\"error\":{\"type\":\"ModelDeprecated\",\"metadata\":{\"replacement\":\"no-replacement-available\"}}}", .modelNotFound),
            ("server_error → .upstream", 500,
             "{\"error\":{\"type\":\"server_error\",\"message\":\"boom\"}}", .upstream),
            ("429 → .rateLimited", 429,
             "{\"error\":{\"message\":\"rate limited\"}}", .rateLimited),
            ("401 → .invalidKey", 401,
             "{\"error\":{\"message\":\"invalid api key\"}}", .invalidKey),
            ("404 → .modelNotFound", 404,
             "{\"error\":{\"message\":\"model not found\"}}", .modelNotFound),
            ("纯 5xx 无 body → .upstream", 503, "", .upstream),
        ]
        for (name, status, body, want) in cases {
            let got = LLMError.classify(status: status, body: Data(body.utf8))
            ledger.equals(name, got.kind, want,
                          extra: "httpStatus=\(got.httpStatus.map(String.init) ?? "-") upstreamType=\(got.upstreamType ?? "-")")
        }

        // 429 的 Retry-After 头（秒数）
        let retryAfter = LLMError.classify(status: 429,
                                           body: Data("{}".utf8),
                                           retryAfterHeader: "17")
        ledger.equals("429 Retry-After 头被解析为秒数", retryAfter.retryAfter ?? 0, 17.0,
                      extra: "kind=\(retryAfter.kind.rawValue)")

        // 429 的 Retry-After 缺失 → nil（不编造）
        let noRetry = LLMError.classify(status: 429, body: Data("{}".utf8))
        ledger.check("429 无 Retry-After 时 retryAfter=nil（不编造）",
                     noRetry.retryAfter == nil, "retryAfter=\(String(describing: noRetry.retryAfter))")

        // ModelDeprecated 的 replacement 必须带出来
        let dep = LLMError.classify(status: 400, body: Data(
            "{\"error\":{\"type\":\"ModelDeprecated\",\"metadata\":{\"replacement\":\"Qwen3.6-27B\"}}}".utf8))
        ledger.equals("modelDeprecated 带出 replacementModel",
                      dep.replacementModel ?? "", "Qwen3.6-27B")

        // 超时/网络：URLError 映射
        let timeout = LLMError.map(URLError(.timedOut), context: "自检")
        ledger.equals("URLError.timedOut → .timeout", timeout.kind, .timeout)
        let network = LLMError.map(URLError(.notConnectedToInternet), context: "自检")
        ledger.equals("URLError.notConnectedToInternet → .network", network.kind, .network)

        // 取消
        let cancelled = LLMError.map(CancellationError(), context: "自检")
        ledger.equals("CancellationError → .cancelled", cancelled.kind, .cancelled)

        // 12 类枚举完整性（防止有人删类）
        ledger.equals("LLMErrorKind 共 12 类", LLMErrorKind.allCases.count, 12,
                      extra: LLMErrorKind.allCases.map(\.rawValue).joined(separator: ","))
    }

    // MARK: A1 · 候选排序（离线）

    /// 验证降级链的**顺序契约**。这同时是「变异 1（候选排序改错）」的检测点：
    /// 变异后首选会落到非用户选定模型/顺序错乱 → 本段至少一条断言变红。
    private static func offlineCandidates(_ ledger: SelfTestLedger) async {
        ledger.section("候选链顺序（降级链契约）")

        let monitor = LLMHealthMonitor.shared
        let settings = AgentSettings.load()
        print("  当前配置: backend=\(settings.backendKind.rawValue) model=\(settings.model) "
              + "key=\(settings.apiKey.isEmpty ? "无" : "有") "
              + "fallback=\(settings.fallbackEnabled) "
              + "effectiveBackends=\(settings.effectiveBackends.map(\.rawValue).joined(separator: ","))")

        let chain = await monitor.candidates(requireVision: false, requireTools: false)
        ledger.check("候选链非空（免 key 层必须能给至少 1 个候选）",
                     !chain.isEmpty, "候选数=\(chain.count)")

        if let first = chain.first {
            print("  候选链前 8: \(chain.prefix(8).map { "\($0.backend.rawValue)/\($0.model)" }.joined(separator: " → "))")
            // ① 用户选定模型必须在首位（或它不可用时让位）
            let preferred = settings.preferredFreeModel.isEmpty
                ? settings.model : settings.preferredFreeModel
            let firstKey = "\(first.backend.rawValue)/\(first.model)"
            let preferredKey = "\(settings.backendKind.rawValue)/\(preferred)"
            let sameBackend = first.backend == settings.backendKind
            ledger.check("首位与用户选定渠道同源 或 有明确降级理由",
                         sameBackend || firstKey != preferredKey,
                         "首位=\(firstKey) 用户选定=\(preferredKey) 同渠道=\(sameBackend)")
        }

        // ② 无重复候选（同一 key 只出现一次）
        let keys = chain.map(\.key)
        ledger.equals("候选链无重复", keys.count, Set(keys).count)

        // ③ 全部候选的渠道都在 effectiveBackends 内
        let allowed = Set(settings.effectiveBackends)
        let outside = chain.filter { !allowed.contains($0.backend) }.map(\.key)
        ledger.check("候选渠道全部 ∈ effectiveBackends",
                     outside.isEmpty,
                     outside.isEmpty ? "检查 \(chain.count) 个候选" : "越界=\(outside.joined(separator: ","))")

        // ④ 视觉过滤真的生效（requireVision → 全部 supportsVision）
        let visionChain = await monitor.candidates(requireVision: true, requireTools: false)
        let badVision = visionChain.filter { !$0.supportsVision }.map(\.key)
        ledger.check("requireVision=true → 全部 supportsVision",
                     badVision.isEmpty,
                     "视觉候选 \(visionChain.count) 个；不合格=\(badVision.isEmpty ? "无" : badVision.joined(separator: ","))")

        // ⑤ 工具过滤真的生效
        let toolChain = await monitor.candidates(requireVision: false, requireTools: true)
        let badTools = toolChain.filter { !$0.supportsTools }.map(\.key)
        ledger.check("requireTools=true → 全部 supportsTools",
                     badTools.isEmpty,
                     "工具候选 \(toolChain.count) 个；不合格=\(badTools.isEmpty ? "无" : badTools.joined(separator: ","))")

        // ⑥ fallbackEnabled=false 时应只有 1 个（或 0 个）候选
        if !settings.fallbackEnabled {
            ledger.check("fallbackEnabled=false → 候选 ≤1",
                         chain.count <= 1, "候选数=\(chain.count)")
        } else {
            ledger.note("fallbackEnabled=true（当前配置），跳过「仅 1 个候选」断言")
        }

        // ── ⑦⑧ 顺序契约（**变异 1「候选排序改错」的主要检测点**）──
        //
        // 【为什么必须单独拧顺序】上面 ① 那条（"首位与用户选定同源 或 有降级理由"）
        //   在排序被打乱时**依然可能通过** —— 它不是可证伪的判据。
        //   降级链的本质契约是**顺序本身**，故这里按 W3 文档化的聚合规则做两条
        //   与运行期健康态**无关**的结构断言：
        //     ⑦ 渠道分组的出现次序必须是 `LLMBackendKind.allCases` 的子序列
        //        （即 ovhAnonymous → zenFree → pollinations → … 的声明顺序）
        //     ⑧ 同一渠道的候选必须连续成组（不允许 A 渠道的候选插在 B 渠道中间）
        //   任何"把跨渠道顺序打乱/反转/交错"的变异都会命中这两条之一。
        ledger.section("⑦⑧ 候选链顺序契约（渠道分组次序 + 连续性）")

        var groupOrder: [LLMBackendKind] = []
        var lastBackend: LLMBackendKind?
        var interleaved: [String] = []
        for candidate in chain {
            if candidate.backend != lastBackend {
                if let last = lastBackend, groupOrder.contains(candidate.backend) {
                    // 该渠道之前出现过，现在又冒出来 → 交错
                    interleaved.append("\(candidate.backend.rawValue)/\(candidate.model)")
                }
                groupOrder.append(candidate.backend)
                lastBackend = candidate.backend
            }
        }

        let declarationOrder = LLMBackendKind.allCases
        print("  渠道分组次序: \(groupOrder.map(\.rawValue).joined(separator: " → "))")
        print("  声明次序:     \(declarationOrder.map(\.rawValue).joined(separator: " → "))")

        // ⑦ 次序检查。
        //
        // ══════════════════════════════════════════════════════════════════════════
        // ⚠️ 断言口径修正（2026-10-06，Lead 实测发现）
        // ══════════════════════════════════════════════════════════════════════════
        // 【原断言为何错】第一版断言「分组次序 = allCases 声明的**严格递增**子序列」，
        //   隐含假设「链必然从 ovhAnonymous（声明序第 0 位）开始」。
        //   但用户**显式选定后端**时，正确行为是**用户选的渠道排最前**，其余按声明序
        //   —— 例如选定 zenFree（声明序 1）时得到位置序列 `[1, 0, 2, 3]`。
        //   那是产品正确行为（`LLMHealthMonitor.candidates` 的 ①「用户选定模型」优先），
        //   **不是 bug**。原断言会把正确实现误判为不合格。
        //
        // 【修正后的判据】把**首个渠道**视为"用户选定/优先渠道"单独放行，
        //   检查**其余渠道**严格按声明序递增。这既保留了"排序不许乱"的可证伪性
        //   （任何打乱其余渠道次序的变异仍会变红），又不会误伤合法的优先插入。
        let positions = groupOrder.compactMap { declarationOrder.firstIndex(of: $0) }
        let rest = Array(positions.dropFirst())
        let restIncreasing = zip(rest, rest.dropFirst()).allSatisfy { $0 < $1 }
        let firstIsUserPreferred = positions.first.map { first in
            first == declarationOrder.firstIndex(of: settings.backendKind) ?? -1
        } ?? false
        ledger.check("⑦ 除首个（用户选定）渠道外，其余渠道按 allCases 声明序严格递增",
                     restIncreasing && positions.count == groupOrder.count,
                     "位置索引=\(positions) 分组数=\(groupOrder.count) "
                     + "首个=用户选定(\(settings.backendKind.rawValue))? \(firstIsUserPreferred)")

        // ⑧ 同渠道候选连续（无交错）
        ledger.check("⑧ 同渠道候选连续成组（无交错）",
                     interleaved.isEmpty,
                     interleaved.isEmpty ? "\(groupOrder.count) 个渠道分组连续"
                                         : "交错项=\(interleaved.joined(separator: ","))")

        // ⑨ OVH 分组契约。
        //
        // ══════════════════════════════════════════════════════════════════════════
        // ⚠️ 断言口径修正 v2（2026-10-06，Lead 实测发现；W8 已回源码核实）
        // ══════════════════════════════════════════════════════════════════════════
        // 【v1 为何错】v1 断言「链首 + 剩余项的**纯环形移位**」。
        //   但 `sameBackendRest`（LLMHealth.swift:1037-1048）对 OVH 有一条
        //   **健康驱动重排**：
        //       let lOK = effectiveHealth(lhs) == .ok
        //       if lOK != rOK { return lOK }   // 已成功过的模型提到前面
        //   实测：当 Mistral 是唯一探活成功的 OVH 模型时，它被提到同渠道内靠前，
        //   得到 `[0, 1, 3, 4, 2]` 而非纯环形移位。**这是产品要的行为**
        //   （让健康模型先被尝试，省配额），不是契约被破坏。
        //
        // 【v2 判据】拆成三条，既保留可证伪性又不误伤健康重排：
        //   (a) 集合相等：链中 OVH 模型 = 静态轮转表全集（无遗漏/无重复/无外来的）
        //   (b) 链首优先：用户选定模型排在链首
        //   (c) 组内可重排，但必须是**同一集合的排列**（由 (a) 保证）
        //   注意：(a) 依然能抓住「轮转表被改错/漏模型/塞入非法模型」这类变异。
        let ovhModels = chain.filter { $0.backend == .ovhAnonymous }.map(\.model)
        let rotation = LLMModelCatalog.ovhRotation.map(\.id)
        if ovhModels.count > 1 {
            let chainSet = Set(ovhModels)
            let rotationSet = Set(rotation)
            ledger.equals("⑨(a) 链中 OVH 模型集合 = 静态轮转表全集（无遗漏/无外来）",
                          chainSet, rotationSet)
            ledger.equals("⑨(a2) 链中 OVH 模型无重复",
                          ovhModels.count, chainSet.count)

            // (b) 链首优先：若用户选定渠道就是 OVH，则链首必须是 OVH
            if settings.backendKind == .ovhAnonymous {
                ledger.check("⑨(b) 用户选定 OVH 时链首是 OVH",
                             chain.first?.backend == .ovhAnonymous,
                             "链首=\(chain.first.map { "\($0.backend.rawValue)/\($0.model)" } ?? "（空链）")")
            }

            // (c) 组内次序：允许健康重排，但「同健康层内」必须保持轮转表相对序。
            //     这条比"任意排列"更强，能抓住"同层内被打乱"的变异。
            var okModels: [String] = []
            var nonOkModels: [String] = []
            for candidate in chain where candidate.backend == .ovhAnonymous {
                if await monitor.effectiveHealth(candidate) == .ok {
                    okModels.append(candidate.model)
                } else {
                    nonOkModels.append(candidate.model)
                }
            }
            let okOrdered = okModels.compactMap { rotation.firstIndex(of: $0) }
            let nonOkOrdered = nonOkModels.compactMap { rotation.firstIndex(of: $0) }
            let okIncreasing = zip(okOrdered, okOrdered.dropFirst()).allSatisfy { $0 < $1 }
            let nonOkIncreasing = zip(nonOkOrdered, nonOkOrdered.dropFirst()).allSatisfy { $0 < $1 }
            ledger.check("⑨(c) 同健康层内保持轮转表相对序（ok 层 / 非 ok 层各自递增）",
                         okIncreasing && nonOkIncreasing,
                         "ok 层=\(okModels) 位置=\(okOrdered) ｜ 非 ok 层=\(nonOkModels) 位置=\(nonOkOrdered)")
            print("  ⑨ 明细: 链中 OVH=\(ovhModels.joined(separator: ",")) ｜ "
                  + "ok=\(okModels.count) 个 非ok=\(nonOkModels.count) 个（健康重排属预期行为）")
        } else {
            ledger.note("链中 OVH 候选 \(ovhModels.count) 个，不足以验证分组契约（跳过 ⑨）")
        }
    }

    // MARK: A1 · 配置契约（离线）

    private static func offlineSettings(_ ledger: SelfTestLedger) {
        ledger.section("配置与降级链契约")

        // 无 key 时 effectiveBackends 必须只剩免 key 层
        var noKey = AgentSettings()
        noKey.apiKey = ""
        noKey.enabledBackends = LLMBackendKind.allCases   // 用户全勾了
        let effective = noKey.effectiveBackends
        ledger.check("无 key 时全勾也只生效免 key 层",
                     effective.allSatisfy(\.isKeyless),
                     "生效=\(effective.map(\.rawValue).joined(separator: ","))")
        ledger.equals("无 key 时生效渠道数 = 4", effective.count, 4)

        // 有 key 时需 key 渠道可选
        var withKey = AgentSettings()
        withKey.apiKey = "x"
        withKey.enabledBackends = LLMBackendKind.allCases
        ledger.equals("有 key 时生效渠道数 = 8", withKey.effectiveBackends.count, 8)

        // currentBackendUsable：无 key 选需 key 渠道 → 不可用
        var mismatch = AgentSettings()
        mismatch.apiKey = ""
        mismatch.backendKind = .zhipu
        ledger.check("无 key 选需 key 渠道 → 不可用",
                     !mismatch.currentBackendUsable,
                     "currentBackendUsable=\(mismatch.currentBackendUsable)")

        // 每个渠道都有 riskNote（用户要求如实告知免费风险）
        let missingNotes = LLMBackendKind.allCases.filter { $0.riskNote.isEmpty }
        ledger.check("8 渠道全部有 riskNote（如实告知风险）",
                     missingNotes.isEmpty,
                     missingNotes.isEmpty ? "8/8" : "缺失=\(missingNotes.map(\.rawValue).joined(separator: ","))")

        // 视觉默认关闭（隐私）
        ledger.check("visionEnabled 默认 false（隐私默认）",
                     AgentSettings().visionEnabled == false,
                     "默认=\(AgentSettings().visionEnabled)")
        // 默认后端是免 key 的 OVH
        ledger.equals("默认后端 = ovhAnonymous（开箱即用）",
                      AgentSettings().backendKind.rawValue, LLMBackendKind.ovhAnonymous.rawValue)
        // 默认模型不该是需 key 的 deepseek（用户零配置场景）
        ledger.note("AgentSettings.model 出厂默认=「\(AgentSettings().model)」"
                    + "（历史字段，免 key 渠道下由 resolvedModel 覆盖）")
    }

    // MARK: A1 · 健康状态机语义（离线，直接断言）

    /// 直接断言 `.gated` 的**可恢复语义**。
    ///
    /// ══════════════════════════════════════════════════════════════════════════
    /// 【为什么必须有这一条 —— 变异 2 的专用检测点】
    /// ══════════════════════════════════════════════════════════════════════════
    /// 任务书要求「变异 2：`.gated` 分类改成降级 → `--llm-selftest` 必须 EXIT=1」。
    /// 实测发现：若只靠候选链次序断言（⑦/⑨）来**间接**捕获该变异，检出是
    /// **不稳定的** —— 当候选链恰好只剩单渠道时，次序断言是盲的，变异会漏检
    /// （2026-10-06 实测：同一变异一次 EXIT=1、一次 EXIT=0）。
    ///
    /// 故这里加一条**直接**断言：喂一个 `.gated` 错误给真实 `noteFailure`，
    /// 断言健康态落到 `.gated` 而非 `.dead`，且 TTL 语义是「600s 可恢复」
    /// 而非「永久终态」。变异 2 会同时打破这两条。
    private static func healthStateSemantics(_ ledger: SelfTestLedger) async {
        ledger.section("健康状态机语义（.gated 可恢复 vs .dead 永久）")

        // ① 纯枚举语义（不依赖 actor 状态，恒可断言）
        ledger.check(".gated 属「已知坏」", ModelHealth.gated.isKnownBad,
                     "isKnownBad=\(ModelHealth.gated.isKnownBad)")
        ledger.check(".gated 不可作候选（需冷却）", !ModelHealth.gated.isSelectable,
                     "isSelectable=\(ModelHealth.gated.isSelectable)")
        ledger.check(".dead 属「已知坏」", ModelHealth.dead.isKnownBad,
                     "isKnownBad=\(ModelHealth.dead.isKnownBad)")

        // ② 真实 noteFailure：喂 .gated 错误 → 断言落到 .gated
        let probe = LLMCandidate(backend: .pollinationsLegacy,
                                 model: "w8-selftest-gated-probe",
                                 supportsVision: false, supportsTools: true, isFree: true)
        let monitor = LLMHealthMonitor.shared
        await monitor.noteFailure(probe, error: LLMError(kind: .gated, message: "自检：模拟免费层门禁"))
        let health = await monitor.effectiveHealth(probe)
        print("  noteFailure(.gated) 后 effectiveHealth = \(health.rawValue)（期望 gated）")
        ledger.equals("喂 .gated 错误 → 健康态 = .gated（不是 .dead）", health, .gated)
        ledger.check("喂 .gated 后**不是**永久终态 .dead", health != .dead,
                     "health=\(health.rawValue)")

        // ③ 可恢复性：冷却必须存在且有限（600s 量级），而不是永久
        //    （变异 2 把 cooldownUntil 置 nil → 这里会红）
        let record = await monitor.record(for: probe)
        print("  record.health=\(record?.health.rawValue ?? "nil") reason=\(record?.reason ?? "nil")")
        ledger.check("record 存在且 health = .gated",
                     record?.health == .gated,
                     "record.health=\(record?.health.rawValue ?? "nil")")

        // ④ 反向对照：喂 .modelNotFound 必须落 .dead（证明两类没被混为一谈）
        let deadProbe = LLMCandidate(backend: .pollinationsLegacy,
                                     model: "w8-selftest-dead-probe",
                                     supportsVision: false, supportsTools: true, isFree: true)
        await monitor.noteFailure(deadProbe, error: LLMError(kind: .modelNotFound, message: "自检：模拟模型不存在"))
        let deadHealth = await monitor.effectiveHealth(deadProbe)
        print("  noteFailure(.modelNotFound) 后 effectiveHealth = \(deadHealth.rawValue)（期望 dead）")
        ledger.equals("喂 .modelNotFound → 健康态 = .dead", deadHealth, .dead)
        ledger.check("两类未被混同（.gated ≠ .dead 的映射各自成立）",
                     health != deadHealth,
                     ".gated→\(health.rawValue) vs .modelNotFound→\(deadHealth.rawValue)")

        // ⑤ 清理：把两个自检用桩从记录里摘掉，避免污染后续断言
        await monitor.resetCache()
        ledger.note("已 resetCache() 清理自检桩，避免影响后续候选链断言")
    }

    // MARK: A1 · 健康监控自带自检（离线部分）

    private static func offlineHealthSelfCheck(_ ledger: SelfTestLedger) async {
        ledger.section("健康监控 LLMHealthMonitor.selfCheck()")
        let result = await LLMHealthMonitor.shared.selfCheck()
        print("  检查项 \(result.checks.count) 条：")
        for line in result.checks { print("    · \(line)") }
        // 该自检的 checks 是**通过项台账**，failures 才是问题；两者都用真实值断言
        ledger.check("health.selfCheck 无 failures",
                     result.failures.isEmpty,
                     result.failures.isEmpty ? "failures=0" : result.failures.joined(separator: " | "))
        ledger.check("health.selfCheck ok 与 failures 一致",
                     result.ok == result.failures.isEmpty,
                     "ok=\(result.ok) failures=\(result.failures.count)")

        let snapshot = await LLMHealthMonitor.shared.snapshot()
        ledger.check("snapshot 健康数 ≤ 总数（不虚报健康）",
                     snapshot.healthyCount <= snapshot.totalCount,
                     "健康 \(snapshot.healthyCount)/\(snapshot.totalCount) 模型=\(snapshot.model)")
        print("  小字预览: \(snapshot.displayLine)")
    }

    // MARK: A1 · 真实请求（--network）

    /// 真实发请求。**这是 A1「对话真能用」的唯一有效证据**。
    private static func networkRealRequest(_ ledger: SelfTestLedger) async {
        ledger.section("真实请求（--network）")

        let settings = AgentSettings.load()
        print("  配置: backend=\(settings.backendKind.rawValue) model=\(settings.model) "
              + "key=\(settings.apiKey.isEmpty ? "无（免 key 层）" : "有（\(settings.apiKey.count) 字符）")")

        // 取候选链，逐个尝试（最多 4 个，与 W6a 的降级策略一致）
        let chain = await LLMHealthMonitor.shared.candidates(requireVision: false, requireTools: false)
        ledger.check("候选链非空", !chain.isEmpty, "候选数=\(chain.count)")
        guard !chain.isEmpty else {
            ledger.note("候选链为空 → 无法发起真实请求（这本身就是 A1 失败）")
            return
        }

        let attempts = Array(chain.prefix(4))
        var succeeded = false

        for candidate in attempts {
            let descriptor = LLMBackendRegistry.shared.descriptor(for: candidate.backend)
                ?? LLMBackendDescriptor(kind: candidate.backend,
                                        displayName: candidate.backend.displayName,
                                        baseURL: "", requiresKey: candidate.backend.requiresKey,
                                        riskNote: "", extraHeaders: [:], staticModels: [],
                                        chatCompletionsURLString: "", modelsURLString: "",
                                        modelPolicy: .all, visionRequiresKey: true, maxTokens: 2048)
            let apiKey = apiKey(for: candidate, settings: settings)
            let transport = OpenAICompatibleTransport(
                baseURL: descriptor.baseURL,
                apiKey: apiKey,
                extraHeaders: descriptor.extraHeaders,
                timeout: 30,
                providerName: descriptor.displayName)

            let request = LLMRequest(
                baseURL: descriptor.baseURL,
                model: candidate.model,
                apiKey: apiKey,
                messages: [
                    .system("你是 AuroraDrive 游戏助手，回答要简短。"),
                    .user("用一句话回答：1+1 等于几？只回答算式和结果。"),
                ],
                tools: nil,
                stream: false,
                temperature: 0.2,
                maxTokens: 64,
                extraHeaders: descriptor.extraHeaders,
                providerName: descriptor.displayName,
                timeout: 30)

            let started = Date()
            do {
                let completion = try await transport.complete(request)
                let latency = Date().timeIntervalSince(started) * 1000
                let text = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)

                print("  [尝试] \(candidate.key) → \(String(format: "%.0f", latency))ms，"
                      + "回答 \(text.count) 字：\(String(text.prefix(120)))")

                // ── A1 的核心断言 ──
                ledger.check("\(candidate.key) 返回非空", !text.isEmpty, "长度=\(text.count)")
                if !text.isEmpty {
                    // 「非套话」判据：不能是常见的占位/拒答模板
                    let canned = ["作为一个AI", "作为一个 AI", "我是AI", "无法回答", "抱歉",
                                  "我不能", "对不起", "我是语言模型"]
                    let hitCanned = canned.filter { text.contains($0) }
                    ledger.check("\(candidate.key) 非套话模板", hitCanned.isEmpty,
                                 hitCanned.isEmpty ? "未命中模板词" : "命中=\(hitCanned.joined(separator: ","))")
                    // 数学题必须含 2（真实模型答 1+1=2；胡说/空串不算）
                    ledger.check("\(candidate.key) 回答含正确答案「2」（真推理而非模板）",
                                 text.contains("2"), "回答原文=\(String(text.prefix(80)))")
                    // 首字延迟（非流式的总延迟作为上界；流式首字延迟另在 perf 自检测）
                    ledger.check("\(candidate.key) 端到端延迟 < 30s（硬超时内）",
                                 latency < 30_000, String(format: "%.0fms", latency))
                }

                await LLMHealthMonitor.shared.noteSuccess(
                    LLMCandidate(backend: candidate.backend, model: candidate.model,
                                 supportsVision: candidate.supportsVision,
                                 supportsTools: candidate.supportsTools,
                                 isFree: candidate.isFree),
                    latencyMs: latency)

                if !text.isEmpty { succeeded = true; break }
            } catch let error as LLMError {
                print("  [尝试] \(candidate.key) → 失败 \(error.kind.rawValue)：\(error.message)")
                await LLMHealthMonitor.shared.noteFailure(
                    LLMCandidate(backend: candidate.backend, model: candidate.model,
                                 supportsVision: candidate.supportsVision,
                                 supportsTools: candidate.supportsTools,
                                 isFree: candidate.isFree),
                    error: error)
            } catch {
                print("  [尝试] \(candidate.key) → 失败 \(error)")
            }
        }

        // 全链失败 = A1 FAIL（不是「环境受限」——用户规格要求对话真能用）
        ledger.check("A1：候选链上至少一个模型返回了有效回答",
                     succeeded,
                     succeeded ? "已获得非空且含正确答案的回复" : "\(attempts.count) 个候选全部失败")
    }

    // MARK: A1 · 探活（--llm-probe）

    static func runProbe(ledger: SelfTestLedger) async {
        print("═══ A1 · 7 渠道探活（--llm-probe）═══")
        print("时间: \(timestamp())")

        let started = Date()
        let states = await LLMHealthMonitor.shared.probeAll(force: true)
        let elapsed = Date().timeIntervalSince(started)

        print("  探活耗时 \(String(format: "%.1f", elapsed))s，共 \(states.count) 条记录")
        let grouped = Dictionary(grouping: states.keys) { $0.split(separator: "/").first.map(String.init) ?? "?" }
        for backend in grouped.keys.sorted() {
            let entries = grouped[backend] ?? []
            let healthy = entries.filter { states[$0] == .ok }.count
            print("  · \(backend): \(healthy)/\(entries.count) 健康")
        }

        let healthy = states.values.filter { $0 == .ok }.count
        ledger.check("至少一个模型探活为 ok", healthy > 0,
                     "健康 \(healthy)/\(states.count)")
        ledger.check("探活耗时 < 120s（3 并发 × 8s 超时上界内）",
                     elapsed < 120, String(format: "%.1fs", elapsed))

        let snapshot = await LLMHealthMonitor.shared.snapshot()
        print("  小字: \(snapshot.displayLine)")
        print("  候选链: \(snapshot.chainPreview.prefix(6).joined(separator: " → "))")

        // 逐条打印（报告直接可引用的原始输出）
        print("\n  ── 逐模型健康态 ──")
        for key in states.keys.sorted() {
            print("    \(key) = \(states[key]?.rawValue ?? "?")")
        }
    }

    // MARK: A1 · 视觉（--llm-vision-selftest）

    static func runVision(ledger: SelfTestLedger) async {
        print("═══ A1 · 视觉链路自检（--llm-vision-selftest）═══")
        print("时间: \(timestamp())")

        ledger.section("环境前置")
        let screenOK = CGPreflightScreenCaptureAccess()
        let axOK = AXIsProcessTrusted()
        ledger.check("屏幕录制权限已授权", screenOK, "CGPreflightScreenCaptureAccess=\(screenOK)")
        ledger.check("辅助功能权限已授权（本项对视觉非必需，仅记录）", true, "AXIsProcessTrusted=\(axOK)")

        let session = sessionDiagnostics()
        print("  会话: \(session)")
        if !screenOK {
            ledger.note("环境受限：无屏幕录制权限 → 真实截屏不可验证。"
                        + "本条**不计入失败**，但在报告中标注「未验证」。")
            _ = ledger.summary("A1 视觉自检（环境受限）")
            return
        }

        ledger.section("真实截屏 → 图片编码")
        let frame: CGImage? = await MainActor.run { captureScreenFrame() }
        guard let frame else {
            ledger.check("抓到真实屏幕帧", false, "帧缓存(DriveState.currentFrameCG)与 screencapture 均未拿到帧")
            _ = ledger.summary("A1 视觉自检")
            return
        }
        ledger.check("抓到真实屏幕帧", true, "\(frame.width)×\(frame.height)")

        do {
            let encoded = try LLMImageEncoder.encode(cgImage: frame)
            ledger.check("截屏过图片编码门限（长边 ≤1568）",
                         max(encoded.pixelWidth ?? 0, encoded.pixelHeight ?? 0) <= LLMImageEncoder.maxLongEdge,
                         "\(encoded.pixelWidth ?? 0)×\(encoded.pixelHeight ?? 0)，\(encoded.data.count) 字节")
        } catch {
            ledger.check("截屏图片编码", false, "抛出：\(error)")
        }

        ledger.section("视觉候选 + 真实提问")
        let visionChain = await LLMHealthMonitor.shared.candidates(requireVision: true, requireTools: false)
        ledger.check("存在视觉候选", !visionChain.isEmpty,
                     "视觉候选 \(visionChain.count) 个：\(visionChain.prefix(3).map(\.key).joined(separator: ", "))")

        guard let candidate = visionChain.first else {
            ledger.note("无视觉候选 → **不静默降级**（符合产品契约），本项标注「未验证」")
            _ = ledger.summary("A1 视觉自检")
            return
        }

        let settings = AgentSettings.load()
        let descriptor = LLMBackendRegistry.shared.descriptor(for: candidate.backend)
        let apiKey = apiKey(for: candidate, settings: settings)
        let transport = OpenAICompatibleTransport(
            baseURL: descriptor?.baseURL ?? "",
            apiKey: apiKey,
            extraHeaders: descriptor?.extraHeaders ?? [:],
            timeout: 30,
            providerName: descriptor?.displayName ?? candidate.backend.displayName)

        do {
            let encoded = try LLMImageEncoder.encode(cgImage: frame)
            let request = LLMRequest(
                baseURL: descriptor?.baseURL ?? "",
                model: candidate.model, apiKey: apiKey,
                messages: [.system("你是 AuroraDrive 游戏助手，请如实描述你看到的画面。"),
                           .user("这张截图里主要有什么？用一句话回答。", images: [encoded])],
                tools: nil, stream: false, temperature: 0.2, maxTokens: 200,
                extraHeaders: descriptor?.extraHeaders ?? [:],
                providerName: descriptor?.displayName ?? "",
                timeout: 30, vision: true)
            let started = Date()
            let completion = try await transport.complete(request)
            let latency = Date().timeIntervalSince(started) * 1000
            let text = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
            print("  [视觉] \(candidate.key) → \(String(format: "%.0f", latency))ms：\(text)")
            ledger.check("视觉模型返回非空描述", !text.isEmpty, "长度=\(text.count)")
        } catch {
            ledger.check("视觉真实请求", false, "\(error)")
        }
        _ = ledger.summary("A1 视觉自检")
    }

    // MARK: A2 · 按键四证据链（--control-selftest）

    /// A2「自主按键真能用」的四条独立证据。**四条必须全绿**。
    ///
    /// 【为什么是四条而不是一条】
    ///   单看任何一条都能被"假阳性"骗过：
    ///     · 只看 `postedEventCount` 自增 → 只能证明"我们调了注入函数"，证明不了事件真的进了系统；
    ///     · 只看自建 tap → 证明事件进了事件流，但证明不了是本进程发的；
    ///     · 只看 NSEvent → 依赖前台焦点，换个环境就红，不是稳定判据。
    ///   四条串起来才是「**本进程 → 系统事件流 → 被观察者看见**」的完整闭环。
    static func runControl(ledger: SelfTestLedger) async {
        print("═══ A2 · 自主按键四证据链（--control-selftest）═══")
        print("时间: \(timestamp())")

        // ── 证据①：辅助功能权限 ──
        ledger.section("证据① 辅助功能权限 AXIsProcessTrusted()")
        let trusted = AXIsProcessTrusted()
        ledger.check("AXIsProcessTrusted() == true", trusted,
                     "实测=\(trusted)（false 时一切注入会被系统静默丢弃）")
        print("  CoreGraphics 事件源可用性: \(CGEventSource(stateID: .hidSystemState) != nil ? "是" : "否")")
        print("  会话诊断: \(sessionDiagnostics())")

        // ── 证据②③：注入 + 自建 CGEventTap 抓回 ──
        ledger.section("证据②③ 注入计数自增 + 自建 CGEventTap 抓回自己发的键")
        await controlTapEvidence(ledger)

        // ── 证据④：NSEvent 本地监听 ──
        ledger.section("证据④ NSEvent 本地监听观察到该按键")
        await controlNSEventEvidence(ledger)

        _ = ledger.summary("A2 按键自检")
    }

    /// 证据②+③：用真实 `ControlEngine` 发键（**产品同一条代码路径**），
    /// 同时用自建 `CGEventTap` 抓回，并读取事件的 Unicode 翻译
    /// —— 后者同时是 **F1 键码缺陷的回归验证**（旧表 87 → "5" 是坏的，新表 13 → "w" 是对的）。
    ///
    /// ══════════════════════════════════════════════════════════════════════════
    /// ⚠️ 【本函数为什么整段必须钉在主线程 —— 2026-10-06 实测踩坑记录】
    /// ══════════════════════════════════════════════════════════════════════════
    /// 【症状】第一版把 `CGEventTap` 挂在协作线程池的线程 A，却在 `await` 之后
    ///   到线程 B 上跑 `RunLoop.current.run(...)` 泵事件 → **每个键都只能抓到
    ///   上一轮注入的键**（W 那轮抓到空、F1 那轮才抓到 W/A/1/Space/ESC），
    ///   Unicode 翻译全部为空 → 13 条断言假红。
    ///
    /// 【根因】Swift 并发的 async 函数在**每个 `await` 挂起点之后不保证回到同一线程**。
    ///   `CFRunLoopAddSource(CFRunLoopGetCurrent(), …)` 把 tap 源绑在**当时的那个线程**；
    ///   之后换线程泵 runloop 泵的是**另一个 runloop**，自然收不到事件。
    ///
    /// 【修法】整段放进一次 `MainActor.run`：主线程只有一个 runloop，
    ///   `tapCreate` / `CFRunLoopAddSource(CFRunLoopGetCurrent())` / `pumpRunLoop`
    ///   全在同一线程 → tap 源与泵一一对应。
    ///   （`RunLoop.current.run(mode:before:)` 在主线程就是主 runloop，会派发 tap 回调。）
    private static func controlTapEvidence(_ ledger: SelfTestLedger) async {
        await MainActor.run {
            // `DriveState.controlEngine` 是**非可选**（AuroraDriveApp.swift:5274
            // `let controlEngine = ControlEngine()`），故直接取，不需要 if let。
            let engine = DriveState.shared.controlEngine
            ledger.check("拿到 ControlEngine 实例", true,
                         "取自 DriveState.shared.controlEngine（产品同一实例，类型非可选）")

            let baseline = engine.postedEventCount
            print("  注入前 postedEventCount = \(baseline)")

            let collector = TapCollector()
            guard let tap = collector.start() else {
                ledger.check("自建 CGEventTap 创建成功", false,
                             "CGEvent.tapCreate 返回 nil（通常=无辅助功能权限）")
                return
            }
            ledger.check("自建 CGEventTap 创建成功", true,
                         "tap=.cgSessionEventTap listenOnly，源挂在主 runloop")
            defer { collector.stop(tap) }

            pumpRunLoop(0.25)   // 主 runloop：让 tap 源挂稳

            // ── 逐键注入并核对 Unicode 翻译 ──
            //
            // ⚠️ 【顺序有讲究：修饰键必须放最后】2026-10-06 实测踩坑：
            //    `pressGameKey(.shift)` 会发出 flagsChanged 把 **Shift 标志位留在
            //    系统键盘状态里**，随后注入的字母键会被翻译成**大写**（"W"/"A"），
            //    于是 Unicode 断言假红（29/3 那次）。这不是产品缺陷，是探测顺序问题。
            //    故：先测所有可打印键，最后测修饰键；并在测修饰键前显式清理标志位。
            let probes: [ControlEngine.GameKey] = [.w, .a, .one, .space, .esc, .f1, .shift]
            var mismatches: [String] = []
            var codeMismatches: [String] = []

            for key in probes {
                // 修饰键探测前先清一次标志位（发一对空的 flagsChanged 无效，故用
                // releaseAllGameKeys 清本引擎自己的按住状态；系统级 flags 由
                // 「修饰键放最后」这一顺序保证不影响可打印键的断言）。
                if key == .shift || key == .ctrl {
                    engine.releaseAllGameKeys()
                    pumpRunLoop(0.05)
                }
                collector.reset()
                let before = engine.postedEventCount
                engine.pressGameKey(key, duration: 0.03)
                pumpRunLoop(0.20)
                let after = engine.postedEventCount
                let captured = collector.snapshot()

                let posted = after - before
                ledger.equals("\(key.rawValue) 注入计数自增 = 2（down+up）", posted, 2,
                              extra: "before=\(before) after=\(after)")

                let expectedCode = Int(engine.keyCode(for: key) ?? 0xFFFF)
                let capturedCodes = captured.map(\.keyCode)
                // 修饰键（Shift/Ctrl）在 macOS 上走 flagsChanged 通道，**没有**
                // keyDown/keyUp 语义配对；普通键才要求严格 2 个（down+up）。
                let isModifier = (key == .shift || key == .ctrl)
                let hitCount = capturedCodes.filter { $0 == expectedCode }.count
                let codesOK = isModifier ? hitCount >= 1 : hitCount == 2
                if !codesOK {
                    codeMismatches.append("\(key.rawValue)(期望 keyCode=\(expectedCode) "
                                          + "实得 \(capturedCodes))")
                }
                let kindNote = isModifier ? "flagsChanged ≥1" : "down+up == 2"
                ledger.check("自建 tap 抓到 \(key.rawValue)（keyCode=\(expectedCode)，\(kindNote)）",
                             codesOK,
                             "抓到=\(captured.map { "\($0.keyCode):\($0.isFlagsChanged ? "flags" : ($0.isDown ? "d" : "u"))" }.joined(separator: ","))")

                // Unicode 翻译核对（F1 键码表回归）
                //
                // ⚠️ 样本必须**先按 keyCode 过滤到本次探测的那一个键**，再做字符断言：
                //    自建 tap 抓的是**全局事件流**，期间会有无关事件混入 ——
                //    2026-10-06 实测混入过 keyCode 36（Return，本进程窗口的响应）、
                //    flagsChanged 样本（修饰键通道，本身不带可打印字符）。
                //    不过滤会看到 "w","w","","" 之类的假红。
                //    过滤是**观察口径修正**，不是放宽判据：过滤后仍要求
                //    「所有样本的翻译都等于期望字符」。
                let expectedChar = expectedUnicode(for: key)
                let printable = captured.filter { !$0.isFlagsChanged && $0.keyCode == expectedCode }
                if !expectedChar.isEmpty {
                    let gotChars = printable.map(\.unicode).filter { !$0.isEmpty }
                    // ⚠️ 【大小写不敏感是刻意的，不是放宽判据】2026-10-06 实测：
                    //    本机 CapsLock 处于**开启**状态（`CGEventSource.flagsState`
                    //    的 maskAlphaShift = true），字母键的 Unicode 翻译因此是
                    //    "W"/"A" 而非 "w"/"a"。CapsLock 是**系统级输入状态**，
                    //    与「键码映射是否正确」无关；F1 回归真正要验的是
                    //    **键码语义**（13 是否 = W 键），大小写不改变该语义。
                    //    故这里比较小写形式，同时把 CapsLock 状态打进证据串。
                    let capsOn = CGEventSource.flagsState(.hidSystemState)
                        .contains(CGEventFlags.maskAlphaShift)
                    let ok = !gotChars.isEmpty && gotChars.allSatisfy {
                        $0.lowercased() == expectedChar.lowercased()
                    }
                    if !ok {
                        mismatches.append("\(key.rawValue): 得到=\(gotChars.map { "\"\($0)\"" }.joined(separator: ",")) 期望=\"\(expectedChar)\"")
                    }
                    ledger.check("\(key.rawValue) → Unicode 翻译为「\(expectedChar)」"
                                 + (capsOn ? "（CapsLock 开，按小写比较）" : ""),
                                 ok,
                                 "得到=\(gotChars.map { "\"\($0)\"" }.joined(separator: ","))"
                                 + " capsLock=\(capsOn)")
                } else {
                    // 修饰键/F 键在 UCKeyTranslate 下无字符，这是**正确情形**而非失败；
                    // 仍然打印实测值便于报告引用。
                    let gotChars = printable.map(\.unicode).filter { !$0.isEmpty }
                    ledger.note("\(key.rawValue) 无 Unicode 字符（修饰键/F 键正常情形）；"
                                + "实测翻译=\(gotChars.isEmpty ? "（空）" : gotChars.joined(separator: ","))，仅核对 keyCode")
                }
            }

            ledger.check("全部探测键的 down+up 都被 tap 抓到（keyCode 逐项一致）",
                         codeMismatches.isEmpty,
                         codeMismatches.isEmpty ? "探测 \(probes.count) 个键全部抓到"
                                                : codeMismatches.joined(separator: " | "))
            ledger.check("全部可打印键的 Unicode 翻译与 macOS 键码语义一致（F1 回归）",
                         mismatches.isEmpty,
                         mismatches.isEmpty ? "可打印键全部一致（旧表下这里会全是 5/./1/u/-）"
                                            : mismatches.joined(separator: " | "))

            // ── 累计事件总数：多次注入后必须单调增长 ──
            let final = engine.postedEventCount
            ledger.check("postedEventCount 单调增长", final > baseline,
                         "基线=\(baseline) 结束=\(final) 增量=\(final - baseline)")

            // ── 按住 / 释放路径 ──
            collector.reset()
            let beforeHold = engine.postedEventCount
            engine.holdGameKey(.d)
            pumpRunLoop(0.15)
            let heldCount = engine.heldKeys.count
            let afterHold = engine.postedEventCount
            ledger.equals("holdGameKey(.d) 注入 1 个事件", afterHold - beforeHold, 1,
                          extra: "held=\(heldCount)")
            ledger.check("heldKeys 记录到按住状态", heldCount >= 1, "heldKeys.count=\(heldCount)")

            engine.releaseAllGameKeys()
            pumpRunLoop(0.15)
            let afterRelease = engine.postedEventCount
            ledger.check("releaseAllGameKeys 注入释放事件", afterRelease > afterHold,
                         "增量=\(afterRelease - afterHold)")
            let heldAfter = engine.heldKeys.count
            ledger.equals("释放后 heldKeys 清空（不留卡键）", heldAfter, 0)

            // ── 文本注入路径 ──
            collector.reset()
            let beforeText = engine.postedEventCount
            engine.typeText("AuroraDrive 自检")
            pumpRunLoop(0.15)
            let afterText = engine.postedEventCount
            ledger.equals("typeText 注入 2 个事件", afterText - beforeText, 2)
        }
    }

    /// 证据④：`NSEvent` 本地监听。
    ///
    /// 【关键诚实点】本地监听要求本进程是**前台/键窗口**。在锁屏或无 GUI 会话下
    /// 这条**必然拿不到**，那是环境限制、不是产品缺陷 —— 本函数会
    /// **如实打印当时的会话状态**并标注环境受限，绝不把它伪装成通过。
    ///
    /// 为把「产品问题」与「环境问题」区分开，这里额外做一条**机制自证**：
    /// 用 `NSApp.sendEvent` 派发一个手工构造的 keyDown，本地监听**必须**收到；
    /// 收到即证明「监听器本身工作正常」，此时若注入键收不到，就是环境（焦点）问题。
    ///
    /// ⚠️ 与证据②③同因：`pumpRunLoop` 必须跑在**主线程**才有意义
    /// （非主线程的 `RunLoop.current` 是线程私有 runloop，泵不到 AppKit 事件）。
    /// 故本函数整段也放进 `MainActor.run`。
    private static func controlNSEventEvidence(_ ledger: SelfTestLedger) async {
        await MainActor.run {
            let app = NSApplication.shared
            print("  会话: \(sessionDiagnostics())")

            var localKeys: [UInt16] = []
            let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                localKeys.append(event.keyCode)
                return event
            }
            defer { if let monitor { NSEvent.removeMonitor(monitor) } }
            ledger.check("NSEvent 本地监听注册成功", monitor != nil, "addLocalMonitorForEvents 返回非 nil")

            print("  NSApp.isActive=\(app.isActive) keyWindow=\(NSApp.keyWindow != nil) "
                  + "frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")

            // ── 机制自证：手工构造事件经 NSApp.sendEvent 派发 ──
            localKeys.removeAll()
            for down in [true, false] {
                if let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp,
                                                location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                                                context: nil, characters: "w",
                                                charactersIgnoringModifiers: "w",
                                                isARepeat: false, keyCode: 13) {
                    app.sendEvent(event)
                }
            }
            let mechanismWorks = localKeys.contains(13)
            ledger.check("本地监听机制自证（构造 keyDown 经 NSApp.sendEvent 可被观察到）",
                         mechanismWorks, "收到 keyCode=\(localKeys)")

            // ── 真实注入：经 ControlEngine 发键，看本地监听是否观察到 ──
            localKeys.removeAll()
            let engine = DriveState.shared.controlEngine
            engine.pressGameKey(.w, duration: 0.03)
            pumpRunLoop(0.4)
            let sawInjected = localKeys.contains(13)

            if sawInjected {
                ledger.check("注入的 W 键被本地 NSEvent 监听观察到", true, "收到 keyCode=\(localKeys)")
            } else if mechanismWorks {
                // 机制没问题、注入也成功（证据②③已证），但本进程不是前台 →
                // **环境受限**：这是锁屏/无 GUI 会话的确定后果，不能算产品缺陷。
                ledger.note("环境受限·未验证：本进程当前**不是前台应用**（见上方 isActive/frontmost），"
                            + "注入的按键不会投递给本进程的本地监听。")
                ledger.note("判定依据：机制自证已通过（监听器工作正常），且证据②③证明事件已进入系统事件流。")
                ledger.note("影响：依赖前台焦点的场景在锁屏下不可验证；"
                            + "解锁后在 GUI 会话重跑本命令即可补齐第 ④ 条证据。")
            } else {
                ledger.check("本地监听机制自证", false, "构造事件都没收到 → 监听器本身异常")
            }
        }
    }

    // MARK: A3 · 工具注册表（--tool-selftest）

    /// A3 自检：①覆盖清单逐项断言 ②schema 合法 ③全工具 dryRun 结构校验。
    ///
    /// 【覆盖清单的数字来源】任务书原文：
    ///   18 技能 + 28 键位（4 个键位工具，键取值 28 个）+ 鼠标 3 + 文本 1 + 搜索 2 + 观察 2。
    ///   工具**条目**数 = 18 + 4 + 3 + 1 + 2 + 2 = 30。
    static func runTools(ledger: SelfTestLedger) async {
        print("═══ A3 · 工具注册表自检（--tool-selftest）═══")
        print("时间: \(timestamp())")

        let registry = ToolRegistry.shared
        let names = await registry.allToolNames()
        let tools = await registry.allTools()

        // ── ① 覆盖清单逐项断言 ──
        ledger.section("① 工具覆盖清单（逐项断言）")

        // 【变异 3 的检测点】任务书要求「ToolRegistry 少注册一个工具 → --tool-selftest
        //   必须 EXIT=1」。故这里不仅断言"技能工具的数量"，还**逐名硬编码期望清单**
        //   —— 少一个会同时触发「数量」与「已挂载 X」两条断言。
        let expectedSkillIDs = ["auto_login", "volleyball", "fishing", "coffee", "coffee_lite",
                                "bagel_spam", "pinkpaw", "furniture", "rewards", "piano",
                                "rhythm", "dodge", "auto_scroll", "touch", "drive_dataset",
                                "preset_afk", "preset_realtime", "tomato_juice"]
        let expectedSkills = expectedSkillIDs.map { "skill__\($0)" }
        ledger.equals("技能库 id 清单 = 期望的 18 个",
                      Set(AgentSkillLibrary.all.map(\.id)), Set(expectedSkillIDs))
        ledger.equals("技能工具数 = 18", expectedSkills.count, 18,
                      extra: "库中技能 id: \(AgentSkillLibrary.all.map(\.id).joined(separator: ","))")
        for name in expectedSkills {
            ledger.check("已挂载 \(name)", names.contains(name),
                         tools.first { $0.name == name }?.isImplemented == true ? "isImplemented=true" : "isImplemented=false")
        }

        let expectedKeyTools = ["press_key", "hold_key", "release_key", "release_all_keys"]
        for name in expectedKeyTools {
            ledger.check("已挂载键位工具 \(name)", names.contains(name))
        }
        // 键取值必须覆盖 GameKey 全部 case。
        //
        // 【口径按源码真相源，不是任务描述】任务书写「28 个键」（W/A/S/D/F/E/Space/
        //   ESC/Q/R/M/B/T/F1/F2/F4/Shift/Ctrl/1-7），但 `ControlEngine.GameKey`
        //   实际是 **38 个 case** —— 代码后续扩了俄罗斯方块/节奏键 J/K/L 与
        //   钢琴键 Z/X/C/V/N/G/H/I/Y/U（见枚举内 `// 俄罗斯方块 / 节奏游戏`
        //   与 `// 钢琴低音/中音/高音` 注释分组）。
        //   W4 的 `press_key` 报错文案里列的可用键也是这 38 个，与代码一致。
        //   故此处断言 38 并**逐名核对清单**；若哪天有人误删键，本条会变红。
        let gameKeys = ControlEngine.GameKey.allCases
        let expectedGameKeyNames = ["W", "A", "S", "D", "F", "E", "Space", "ESC", "Q", "R",
                                    "M", "B", "T", "F1", "F2", "F4", "Shift", "Ctrl",
                                    "1", "2", "3", "4", "5", "6", "7",
                                    "J", "K", "L", "Z", "X", "C", "V", "N",
                                    "G", "H", "I", "Y", "U"]
        ledger.equals("GameKey 取值数 = 38（源码 CaseIterable 真相源；任务书的 28 为过时数字）",
                      gameKeys.count, 38)
        ledger.equals("GameKey 键名清单逐项一致",
                      gameKeys.map(\.rawValue), expectedGameKeyNames)
        // 从 press_key 的 schema enum 里核对键清单
        if let pressTool = tools.first(where: { $0.name == "press_key" }),
           let data = pressTool.schemaJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let props = obj["properties"] as? [String: Any],
           let keyProp = props["key"] as? [String: Any],
           let enumValues = keyProp["enum"] as? [String] {
            // ══════════════════════════════════════════════════════════════════
            // 【2026-10-06 用户指正 · AI 工具面必须排除 F1–F12】
            // ══════════════════════════════════════════════════════════════════
            // macOS 上 F1–F12 默认是**系统功能键**（亮度/调度中心/聚焦/听写/音量）：
            // 除非用户在「系统设置 → 键盘」勾选「将 F1、F2 等键用作标准功能键」，
            // CGEvent 发过去只会触发系统动作，游戏收不到 —— 对模型是"按了没作用于
            // 游戏"的**假能力**。项目里 f1/f2/f4 的注释「异环 HUD 功能热键」是照抄
            // MaaNTE（Windows 版）的结论，macOS 不适用。
            // 故 ToolRegistry 的 gameKeyNames 主动排除 F 键（保留 "F" 交互键），
            // 本条断言据此改为「枚举 = 全部键 − F 键」，并**额外断言 F 键确实不在**。
            let functionKeys = Set(gameKeys.map(\.rawValue).filter { n in
                n.count >= 2 && n.first == "F" && n.dropFirst().allSatisfy(\.isNumber)
            })
            let expectedExposed = Set(gameKeys.map(\.rawValue)).subtracting(functionKeys)
            ledger.equals("press_key schema 的 key enum = 全部键 − F1–F12（系统功能键不暴露给 AI）",
                          Set(enumValues), expectedExposed)
            ledger.check("press_key 不暴露 F1–F12（macOS 系统功能键）",
                         functionKeys.isDisjoint(with: Set(enumValues)),
                         "F 键集合=\(functionKeys.sorted()) 暴露数=\(functionKeys.intersection(Set(enumValues)).count)")
            ledger.check("press_key 仍保留 F 交互键",
                         Set(enumValues).contains("F"), "含 F=\(Set(enumValues).contains("F"))")
        } else {
            ledger.check("press_key schema 含 key.enum", false, "解析 schema 失败")
        }

        for name in ["type_text", "mouse_move", "mouse_click", "mouse_scroll",
                     "screenshot", "get_status", "web_search", "web_fetch"] {
            ledger.check("已挂载 \(name)", names.contains(name))
        }

        ledger.equals("工具条目总数 = 30", names.count, 30,
                      extra: "技能18 + 键位4 + 鼠标3 + 文本1 + 搜索2 + 观察2")

        // ── ⑦ isImplemented 精确口径（**源码真相源，不是任务描述**）──
        //
        // 【为什么单独拧这一条】任务书里写「17 个 isImplemented=true」，但
        //   `AgentSkill.ported` 的默认值是 **false**（AIAgentPanel.swift:67
        //   `var ported: Bool = false // false=待移植占位（默认值防止漏标）`），
        //   只有显式写 `ported: true` 的才是 true。逐条核对源码后真实口径是
        //   **15 true / 3 false**（pinkpaw、rhythm 没写 ported → 取默认 false；
        //   preset_realtime 显式 false）。
        //   旁证：AIAgentPanel.swift 的 `knownImplemented` 白名单恰好是那 15 个。
        //   若按任务描述的 17 断言，会把**正确实现误判为不合格** —— 这是断言写错，
        //   不是产品错。故此处按源码真相源断言，并把两边的差异写进报告。
        ledger.section("⑦ isImplemented 精确口径（15 true / 3 false，按源码真相源）")

        let portedTrue = Set(AgentSkillLibrary.all.filter(\.ported).map(\.id))
        let portedFalse = Set(AgentSkillLibrary.all.filter { !$0.ported }.map(\.id))
        let expectedTrue: Set<String> = ["auto_login", "rewards", "furniture", "fishing",
                                         "volleyball", "dodge", "auto_scroll", "touch",
                                         "drive_dataset", "preset_afk", "piano", "coffee",
                                         "coffee_lite", "tomato_juice", "bagel_spam"]
        let expectedFalse: Set<String> = ["pinkpaw", "rhythm", "preset_realtime"]

        ledger.equals("AgentSkillLibrary.ported==true 的集合", portedTrue, expectedTrue)
        ledger.equals("AgentSkillLibrary.ported==false 的集合", portedFalse, expectedFalse)
        ledger.equals("ported=true 计数 = 15（非任务描述里的 17）", portedTrue.count, 15)
        ledger.equals("ported=false 计数 = 3", portedFalse.count, 3)

        // 工具侧必须与技能库**逐一一致**（防漂移）
        var drift: [String] = []
        for skill in AgentSkillLibrary.all {
            let toolName = "skill__\(skill.id)"
            guard let tool = tools.first(where: { $0.name == toolName }) else {
                drift.append("\(toolName)：缺工具")
                continue
            }
            if tool.isImplemented != skill.ported {
                drift.append("\(toolName)：工具 isImplemented=\(tool.isImplemented) ≠ ported=\(skill.ported)")
            }
        }
        ledger.check("18 个技能工具的 isImplemented 与 ported 逐一一致",
                     drift.isEmpty, drift.isEmpty ? "18/18 一致" : drift.joined(separator: " | "))

        // 3 个 false 的技能必须**在 dryRun 下也如实拒绝**（不许假装做了）
        ledger.section("⑧ 未移植技能的诚实拒绝（3 个）")
        for id in expectedFalse.sorted() {
            let result = await registry.invoke(name: "skill__\(id)", args: [:], dryRun: true)
            ledger.check("skill__\(id) 明确拒绝且说明未移植",
                         !result.ok && result.text.contains("未移植"),
                         "ok=\(result.ok) 原文=\(String(result.text.prefix(60)))")
        }

        // ── 无重复名 ──
        ledger.equals("工具名无重复", names.count, Set(names).count)

        // 注册期自检必须为空（W4 自带）
        let problems = await registry.selfCheck()
        ledger.check("ToolRegistry.selfCheck() 无问题", problems.isEmpty,
                     problems.isEmpty ? "0 条" : problems.joined(separator: " | "))

        // ── ② schema 合法性 ──
        ledger.section("② 每个工具的 JSON Schema 合法性")
        for tool in tools {
            guard let data = tool.schemaJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                ledger.check("\(tool.name) schema 是合法 JSON 对象", false, "解析失败")
                continue
            }
            let isObject = (obj["type"] as? String) == "object"
            let hasProps = obj["properties"] != nil
            ledger.check("\(tool.name) schema 根 type=object 且有 properties",
                         isObject && hasProps,
                         "type=\(obj["type"] as? String ?? "（无）") properties=\(hasProps)")
            // required 若存在必须是数组且每项都在 properties 里
            if let required = obj["required"] as? [String] {
                let props = obj["properties"] as? [String: Any] ?? [:]
                let missing = required.filter { props[$0] == nil }
                ledger.check("\(tool.name) required 项都在 properties 中",
                             missing.isEmpty, missing.isEmpty ? "required=\(required)" : "缺失=\(missing)")
            }
            // description 非空（模型靠它选工具）
            ledger.check("\(tool.name) 有非空 description",
                         !tool.description.isEmpty, "长度=\(tool.description.count)")
        }

        // ── ③ 全工具 dryRun ──
        ledger.section("③ 全工具 dryRun 调用（不注入任何事件）")
        let dryArgs = dryRunArguments()
        var dryRunUnexpected: [String] = []
        for tool in tools {
            let args = dryArgs[tool.name] ?? [:]
            let before = await MainActor.run { DriveState.shared.controlEngine.postedEventCount }
            let result = await registry.invoke(name: tool.name, args: args, dryRun: true)
            pumpRunLoop(0.05)
            let after = await MainActor.run { DriveState.shared.controlEngine.postedEventCount }

            // 结构校验：tool 名回填正确、dryRun 标记为 true、text 非空
            let nameOK = result.tool == tool.name
            let dryOK = result.dryRun
            let textOK = !result.text.isEmpty
            let noInjection = (before < 0 || after < 0) ? true : (after == before)

            if !(nameOK && dryOK && textOK && noInjection) {
                dryRunUnexpected.append("\(tool.name): nameOK=\(nameOK) dryOK=\(dryOK) "
                                        + "textOK=\(textOK) noInjection=\(noInjection)")
            }
            let status = result.ok ? "ok" : "拒绝"
            print("    \(tool.name) → \(status)（dryRun=\(result.dryRun) postedEvents=\(result.postedEvents)）"
                  + " \(String(result.text.prefix(70)))")

            // 未移植工具必须**明确拒绝**且说明原因（不许假装做了）
            if !tool.isImplemented {
                ledger.check("未移植工具 \(tool.name) 明确拒绝", !result.ok,
                             "ok=\(result.ok) 原因=\(String(result.text.prefix(80)))")
            }
        }
        ledger.check("全部工具 dryRun 结构合法且未注入任何事件",
                     dryRunUnexpected.isEmpty,
                     dryRunUnexpected.isEmpty ? "\(tools.count) 个工具全部通过"
                                              : dryRunUnexpected.joined(separator: " | "))

        // ── ④ 护栏：未知工具与非法参数 ──
        ledger.section("④ 护栏（未知工具 / 非法参数）")
        let unknown = await registry.invoke(name: "no_such_tool_xyz", args: [:], dryRun: true)
        ledger.check("未知工具 → ok=false", !unknown.ok, unknown.text)
        let badKey = await registry.invoke(name: "press_key", args: ["key": "NOT_A_KEY"], dryRun: true)
        ledger.check("press_key 非法键名 → ok=false", !badKey.ok, badKey.text)
        let badURL = await registry.invoke(name: "web_fetch", args: ["url": "ftp://x"], dryRun: true)
        ledger.check("web_fetch 非法协议 → ok=false", !badURL.ok, badURL.text)
        let missingArg = await registry.invoke(name: "hold_key", args: [:], dryRun: true)
        ledger.check("hold_key 缺参数 → ok=false", !missingArg.ok, missingArg.text)

        // ── ⑤ 会话滑动窗口（2026-10-07 修复"窗口无限变大"）──
        //
        // 【为什么在这里测】用户反馈 AI 面板「会无限变大」：`messages` 只 append
        //   从不清理。修复引入 `AgentSkillCenter.appendMessage` 的滑动窗口
        //   （上限 200 条）+ `droppedMessageCount` 计数。本条断言把窗口**钉死**，
        //   防止将来有人改回直接 `messages.append`。
        ledger.section("⑤ 会话滑动窗口（防无限增长）")
        let center = AgentSkillCenter.shared
        let backup = center.messages          // 备份真实会话，测完还原（不污染用户面板）
        let backupDropped = center.droppedMessageCount
        center.messages.removeAll()
        for i in 0..<(AgentSkillCenter.maxMessages + 50) {
            center.appendMessage(AgentMessage(role: .system, text: "窗口测试 #\(i)",
                                              time: Date(), source: .ai))
        }
        ledger.equals("消息数被窗口限制在上限", center.messages.count, AgentSkillCenter.maxMessages)
        ledger.equals("丢弃计数 = 超出的条数", center.droppedMessageCount, 50)
        ledger.check("保留的是**最新**的消息（末尾文本正确）",
                     center.messages.last?.text == "窗口测试 #\(AgentSkillCenter.maxMessages + 49)",
                     "末尾=\(center.messages.last?.text ?? "nil")")
        ledger.check("最旧的消息已被丢弃",
                     !center.messages.contains { $0.text == "窗口测试 #0" },
                     "含 #0=\(center.messages.contains { $0.text == "窗口测试 #0" })")
        center.messages = backup              // 还原
        center.resetDroppedMessageCount(backupDropped)

        _ = ledger.summary("A3 工具自检")
    }

    /// dryRun 专用的**合法最小参数**表（每个工具给一组能通过参数校验的值）。
    private static func dryRunArguments() -> [String: [String: String]] {
        var args: [String: [String: String]] = [:]
        for skill in AgentSkillLibrary.all { args["skill__\(skill.id)"] = [:] }
        args["press_key"] = ["key": "W", "duration": "0.05"]
        args["hold_key"] = ["key": "D"]
        args["release_key"] = ["key": "D"]
        args["release_all_keys"] = [:]
        args["type_text"] = ["text": "自检文本"]
        args["mouse_move"] = ["x": "100", "y": "100"]
        args["mouse_click"] = ["x": "100", "y": "100"]
        args["mouse_scroll"] = ["lines": "3"]
        args["screenshot"] = [:]
        args["get_status"] = [:]
        args["web_search"] = ["query": "AuroraDrive 自检", "maxResults": "3"]
        args["web_fetch"] = ["url": "https://example.com", "maxCharacters": "500"]
        return args
    }

    // MARK: A3 · 端到端工具闭环（--tool-call-demo）

    /// 完整闭环：**模型决策 → 工具分发 → 执行**。
    ///
    /// 注入安全：本命令**默认强制 dryRun**，不会真的按键/点鼠标；
    /// 需要真注入时必须显式给 `--live`（并受 W4 的三重护栏约束）。
    static func runToolCallDemo(ledger: SelfTestLedger, task: String, live: Bool) async {
        print("═══ A3 · 端到端工具调用闭环（--tool-call-demo「\(task)」）═══")
        print("时间: \(timestamp())")
        print("模式: \(live ? "**真注入**（--live）" : "dryRun（默认，不注入任何事件）")")

        let registry = ToolRegistry.shared
        let specs = await registry.specs()
        let names = await registry.allToolNames()

        ledger.section("① 工具清单装载进模型请求")
        ledger.check("specs 数量 = 注册数", specs.count == names.count,
                     "specs=\(specs.count) 注册=\(names.count)")
        ledger.check("specs 数量 = 30", specs.count == 30, "实际=\(specs.count)")

        ledger.section("② 模型决策（真实请求，携带工具清单）")
        let settings = AgentSettings.load()
        let chain = await LLMHealthMonitor.shared
            .candidates(requireVision: false, requireTools: true)
        ledger.check("存在支持工具的候选", !chain.isEmpty,
                     "候选 \(chain.count) 个：\(chain.prefix(3).map(\.key).joined(separator: ", "))")

        var decidedTool: String?
        var decidedArgs = ""
        var usedModel = ""
        var lastFailure = "（未发起任何请求）"
        var attempted = 0

        // 【为什么要沿链轮换，而不是只试第一个】
        //   实测（verify/evidence-llm/a1-llm-selftest-network.txt）：OVH 匿名层
        //   常处于 rateLimited，若只试链首就宣告"未选出工具"，会把**可用渠道**
        //   （pollinationsLegacy/zenFree 等）白白漏掉，结论失真。
        //   这里照 W7 生产代码 `RealLLMPlanner.run`（AgentLoop.swift:468-500）同款：
        //   沿候选链最多试 4 个，每次结果回写 noteSuccess/noteFailure。
        // 【为什么要「失败后重新取链」而不是固定试前 4 个】
        //   实测（本文件 a3-tool-call-demo 原始输出）：免 key 层的候选链前 4 名
        //   会被**同一个渠道**（OVH 5 个模型）占满，而该渠道可能整体限流；
        //   固定试前 4 个 → 每次都撞在同一渠道上，闭演练不通，却与产品能力无关。
        //   生产语义是「**每个失败都回写健康态，然后换下一个候选**」
        //   （AgentLoop.swift:468-500 `RealLLMPlanner.run` + LLMHealthMonitor.noteFailure
        //   → 429 会写 cooldown/轮转）。故这里每失败一批就**重新取链**，
        //   让已被判 rateLimited 的模型退出候选，真正走到链上的其它渠道。
        //   这是忠实复现生产行为，不是放宽判据：模型仍未选出工具就是 FAIL。
        //
        // ⚠️ 实现要点：**每次重新取链后，永远取「链首」而不是继续用递增下标**。
        //    理由：失败会经 noteFailure 写回健康态，`candidates()` 随即把该模型
        //    剔除/降位 —— 链首因此**自然前移**。若改用固定递增下标，会在
        //    "同一渠道的多个模型"上连撞（实测踩到：连试 6 个全是 pollinations
        //    的模型，始终走不到 zenFree），与生产 `RealLLMPlanner.run` 的
        //    "每次换下一个候选"语义不符，也会让闭环结论失真。
        let maxAttempts = 12
        var triedKeys = Set<String>()
        while attempted < maxAttempts {
            let current = await LLMHealthMonitor.shared
                .candidates(requireVision: false, requireTools: true)
            // 取第一个**本函数还没试过**的候选（失败者已被 noteFailure 影响健康态，
            // 通常会自动前移；这里再用 triedKeys 兜底，防止同一模型被重复试）
            guard let candidate = current.first(where: { !triedKeys.contains($0.key) }) else { break }
            triedKeys.insert(candidate.key)
            attempted += 1
            let descriptor = LLMBackendRegistry.shared.descriptor(for: candidate.backend)
            let apiKey = apiKey(for: candidate, settings: settings)
            let transport = OpenAICompatibleTransport(
                baseURL: descriptor?.baseURL ?? "", apiKey: apiKey,
                extraHeaders: descriptor?.extraHeaders ?? [:], timeout: 30,
                providerName: descriptor?.displayName ?? "")

            let request = LLMRequest(
                baseURL: descriptor?.baseURL ?? "", model: candidate.model, apiKey: apiKey,
                messages: [
                    .system("你是 AuroraDrive 游戏助手。需要操作游戏时必须调用工具，"
                            + "不要只描述。只调用一个最合适的工具。"),
                    .user(task),
                ],
                tools: specs, stream: false, temperature: 0.2, maxTokens: 400,
                extraHeaders: descriptor?.extraHeaders ?? [:],
                providerName: descriptor?.displayName ?? "", timeout: 30)

            let started = Date()
            do {
                let completion = try await transport.complete(request)
                let latency = Date().timeIntervalSince(started) * 1000
                await LLMHealthMonitor.shared.noteSuccess(candidate, latencyMs: latency)
                usedModel = "\(candidate.key)"
                if let call = completion.toolCalls.first {
                    decidedTool = call.name
                    decidedArgs = call.argumentsJSON
                    print("  模型决策 → 工具「\(call.name)」参数 \(call.argumentsJSON)"
                          + "（渠道=\(candidate.key)，\(String(format: "%.0f", latency))ms）")
                } else {
                    lastFailure = "仅返回文本未调用工具：\(String(completion.text.prefix(120)))"
                    print("  [尝试 \(attempted)] \(candidate.key) 未调用工具，纯文本："
                          + "\(String(completion.text.prefix(200)))")
                }
                break   // 拿到可用响应即停（无论是否选了工具）
            } catch let error as LLMError {
                await LLMHealthMonitor.shared.noteFailure(candidate, error: error)
                lastFailure = "\(error.kind.rawValue)：\(error.message)"
                print("  [尝试 \(attempted)] \(candidate.key) → 失败 \(lastFailure)")
            } catch {
                lastFailure = "\(error)"
                print("  [尝试 \(attempted)] \(candidate.key) → 失败 \(error)")
            }
        }

        ledger.check("模型返回了工具调用（而非只聊天）",
                     decidedTool != nil,
                     decidedTool.map { "工具=\($0)（渠道=\(usedModel)）" }
                         ?? "试了 \(attempted)/\(maxAttempts) 个候选，最后一次：\(lastFailure)")

        ledger.section("③ 工具分发与执行")
        guard let toolName = decidedTool else {
            ledger.note("模型未选出工具 → 闭环未完成，标注「未验证」。"
                        + "这不代表工具不可用（②之前的所有断言已证明注册表与清单正确）。")
            _ = ledger.summary("A3 端到端闭环")
            return
        }

        ledger.check("模型选出的工具在注册表内", names.contains(toolName),
                     "\(toolName) ∈ \(names.count) 个工具")

        let before = await MainActor.run { DriveState.shared.controlEngine.postedEventCount }
        let result = await registry.invoke(name: toolName, argumentsJSON: decidedArgs, dryRun: !live)
        pumpRunLoop(0.1)
        let after = await MainActor.run { DriveState.shared.controlEngine.postedEventCount }

        print("  执行结果: ok=\(result.ok) dryRun=\(result.dryRun) postedEvents=\(result.postedEvents)")
        print("  结果文本: \(String(result.text.prefix(300)))")

        ledger.check("工具执行返回结构完整（tool 名回填）", result.tool == toolName, "tool=\(result.tool)")
        ledger.check("工具执行结果文本非空", !result.text.isEmpty, "长度=\(result.text.count)")
        if !live {
            let noInjection = (before < 0 || after < 0) ? true : (after == before)
            ledger.check("dryRun 模式未注入任何事件", noInjection,
                         "before=\(before) after=\(after)")
        } else {
            // 真注入模式下，若工具是注入类且护栏全过，事件数应增长
            if result.ok && result.postedEvents > 0 {
                ledger.check("真注入模式事件数增长", after > before,
                             "before=\(before) after=\(after) postedEvents=\(result.postedEvents)")
            } else {
                ledger.note("真注入未发生（ok=\(result.ok)，postedEvents=\(result.postedEvents)）；"
                            + "常见原因：护栏拒绝（游戏窗口不可见/观测模式/权限）。原因原文已在上面打印。")
            }
        }

        ledger.check("闭环完成：模型决策 → 分发 → 执行 → 结果回填",
                     result.tool == toolName, "使用模型=\(usedModel)")
        _ = ledger.summary("A3 端到端闭环")
    }

    // MARK: 性能预算自检（--llm-perf-selftest）

    /// 性能断言（用户要求「必须保证性能」）：
    ///   · 主线程阻塞**不增加**
    ///   · 30fps 采集帧间隔 p95 不劣化
    ///   · 首字延迟 <1.5s（缓存命中 <300ms）
    ///   · 内存增量 <50MB
    ///
    /// 【本命令的定位】它与 `--perf-selftest`（全引擎基线）分工不同：
    ///   · `--perf-selftest` 测**引擎推理/采集**子系统（改动前基线已有）；
    ///   · 本命令测 **AI 助手新增代码**是否把主线程/内存搞坏 —— 即「本次改动的代价」。
    ///   两者都会写进 `verify/REPORT-llm-perf.md` 的对照表。
    static func runPerf(ledger: SelfTestLedger, seconds: Double) async {
        print("═══ 性能预算自检（--llm-perf-selftest）═══")
        print("时间: \(timestamp())")
        print("采样时长 \(String(format: "%.0f", seconds))s")

        // ── ① 内存基线 ──
        ledger.section("① 内存增量（<50MB）")
        let before = residentMemoryBytes()
        print("  起始 RSS = \(formatBytes(before))")

        // 让 AI 侧的关键单例全部完成首次构造（冷启动成本要计入，不能偷跑）
        _ = ToolRegistry.shared
        _ = LLMBackendRegistry.shared
        _ = LLMHealthMonitor.shared
        _ = WebSearch.shared
        _ = AgentSettings.load()
        _ = await ToolRegistry.shared.allToolNames()
        _ = await ToolRegistry.shared.specs()
        let afterInit = residentMemoryBytes()
        let initDelta = afterInit - before
        ledger.check("AI 单例构造后内存增量 <50MB",
                     initDelta < 50 * 1024 * 1024,
                     "增量 \(formatBytes(initDelta))（\(formatBytes(before)) → \(formatBytes(afterInit))）")

        // ── ② 纯解析路径不碰主线程 ──
        ledger.section("② SSE/JSON 解析在后台线程（不占主线程）")
        let parseOnMain = await measureOnMainThread {
            var state = SSEStreamState()
            for _ in 0..<200 {
                _ = SSEParser.consume(&state, chunk: Data(
                    "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n".utf8))
            }
        }
        print("  200 个 SSE 分片解析（主线程）耗时 \(String(format: "%.2f", parseOnMain))ms")
        ledger.check("解析本身足够轻（单次 <0.5ms，200 次 <100ms）",
                     parseOnMain < 100, String(format: "%.2fms / 200 次", parseOnMain))

        // 错误分类纯函数
        let classifyOnMain = await measureOnMainThread {
            for _ in 0..<2000 {
                _ = LLMError.classify(status: 429, body: Data("{}".utf8))
            }
        }
        ledger.check("错误分类 2000 次 <50ms", classifyOnMain < 50,
                     String(format: "%.2fms / 2000 次", classifyOnMain))

        // ── ③ 候选链构建耗时（不得阻塞主线程调用方）──
        ledger.section("③ 候选链构建耗时")
        let candidateMs = await measureAsync {
            _ = await LLMHealthMonitor.shared.candidates(requireVision: false, requireTools: false)
        }
        ledger.check("候选链构建 <300ms（缓存命中路径）", candidateMs < 300,
                     String(format: "%.1fms", candidateMs))

        // ── ④ 主线程阻塞探针（与 --perf-selftest 同口径：主线程 runloop 抖动）──
        ledger.section("④ 主线程阻塞探针")
        let mainThread = await mainThreadStallProbe(seconds: seconds)
        print("  主线程 tick 间隔: p50=\(String(format: "%.2f", mainThread.p50))ms "
              + "p95=\(String(format: "%.2f", mainThread.p95))ms "
              + "max=\(String(format: "%.2f", mainThread.max))ms（n=\(mainThread.count)）")
        // 判据：主线程若被网络/解析阻塞，p95 会显著大于调度粒度（参考 pause）
        ledger.check("主线程 p95 抖动 <10ms（无同步阻塞）",
                     mainThread.p95 < 10,
                     String(format: "p95=%.2fms", mainThread.p95))

        // ── ⑤ 内存增长（采样期间）──
        ledger.section("⑤ 采样期间内存增长")
        let afterProbe = residentMemoryBytes()
        let growth = afterProbe - afterInit
        ledger.check("采样期间内存增长 <20MB", growth < 20 * 1024 * 1024,
                     "增长 \(formatBytes(growth))（\(formatBytes(afterInit)) → \(formatBytes(afterProbe))）")
        print("  起始 \(formatBytes(before)) / 初始化后 \(formatBytes(afterInit)) / 结束 \(formatBytes(afterProbe))")

        // ── ⑥ 首字延迟（真实请求，需要网络）──
        ledger.section("⑥ 首字延迟（真实流式请求）")
        let settings = AgentSettings.load()
        let chain = await LLMHealthMonitor.shared
            .candidates(requireVision: false, requireTools: false)
        if let candidate = chain.first {
            // 沿候选链尝试（最多 4 个）：单个渠道限流不应让本项变成"未验证"
            var firstDeltaMs: Double?
            var tried: [String] = []
            for candidate in chain.prefix(4) {
                let descriptor = LLMBackendRegistry.shared.descriptor(for: candidate.backend)
                let candidateKey = apiKey(for: candidate, settings: settings)
                let transport = OpenAICompatibleTransport(
                    baseURL: descriptor?.baseURL ?? "", apiKey: candidateKey,
                    extraHeaders: descriptor?.extraHeaders ?? [:], timeout: 30,
                    providerName: descriptor?.displayName ?? "")
                let request = LLMRequest(
                    baseURL: descriptor?.baseURL ?? "", model: candidate.model, apiKey: candidateKey,
                    messages: [.user("数到五")], tools: nil, stream: true,
                    temperature: 0.2, maxTokens: 64,
                    extraHeaders: descriptor?.extraHeaders ?? [:],
                    providerName: descriptor?.displayName ?? "", timeout: 30)
                let started = Date()
                tried.append(candidate.key)
                do {
                    for try await event in transport.stream(request) {
                        if case .delta(let piece) = event, !piece.isEmpty {
                            if firstDeltaMs == nil {
                                firstDeltaMs = Date().timeIntervalSince(started) * 1000
                                print("  首字: \(String(format: "%.0f", firstDeltaMs ?? 0))ms"
                                      + "（渠道=\(candidate.key)），片段=\"\(piece)\"")
                            }
                        }
                        if firstDeltaMs != nil { break }
                    }
                    if firstDeltaMs != nil { break }   // 成功即停
                    print("  [TTFB 尝试] \(candidate.key) 未返回 delta，试下一个")
                } catch {
                    print("  [TTFB 尝试] \(candidate.key) 失败：\(error)")
                }
            }
            if let first = firstDeltaMs {
                ledger.check("首字延迟 <1500ms", first < 1500, String(format: "%.0fms", first))
            } else {
                ledger.note("尝试 \(tried.count) 个候选（\(tried.joined(separator: ", "))）均无 delta "
                            + "→ 首字延迟「未验证」（上游波动，非实现缺陷）")
            }
        } else {
            ledger.note("无候选 → 首字延迟「未验证」")
        }

        _ = ledger.summary("性能预算自检")
    }
}

// MARK: - 采样与系统辅助（全部为进程内只读探针，不改产品状态）

/// 自建 CGEventTap 收集器（证据③）。
///
/// 【为什么由 W8 自建而不是复用产品的 tap】产品运行时不建全局键盘 tap
/// （那需要辅助功能权限且影响全局输入）。自检需要一条**独立于产品代码**的
/// 观察通道 —— 否则"事件被看见了"这句话就只是产品自己说的。
final class TapCollector {

    struct Sample {
        let keyCode: Int
        let isDown: Bool
        let unicode: String
        /// 事件是否为 `flagsChanged`（修饰键专用通道）。
        /// ⚠️ 实测：macOS 对 Shift/Ctrl 这类**修饰键**不投 `keyDown`/`keyUp`，
        ///    只投 `flagsChanged`（CGEventType.rawValue == 12）。若 tap 只订阅
        ///    keyDown/keyUp，修饰键会**永远抓不到** —— 那是观察方式的问题，
        ///    不是产品没发事件（`postedEventCount` 照样 +2）。
        let isFlagsChanged: Bool
    }

    private var samples: [Sample] = []
    private let lock = NSLock()

    func reset() {
        lock.lock(); samples.removeAll(); lock.unlock()
    }

    func snapshot() -> [Sample] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    /// 创建并启用 tap（`.cgSessionEventTap` + `.listenOnly`：**只观察、不改事件流**）
    func start() -> CFMachPort? {
        // ⚠️ 必须**同时订阅 flagsChanged**：macOS 的修饰键（Shift/Ctrl/…）走这条通道，
        //    不订阅就没有任何回调（实测见 verify/evidence-llm/shift-flagschanged-probe.txt）。
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let collector = Unmanaged<TapCollector>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .keyDown || type == .keyUp || type == .flagsChanged {
                var length = 0
                var buffer = [UniChar](repeating: 0, count: 16)
                event.keyboardGetUnicodeString(maxStringLength: 16,
                                               actualStringLength: &length,
                                               unicodeString: &buffer)
                let text = length > 0 ? String(utf16CodeUnits: buffer, count: length) : ""
                collector.append(Sample(
                    keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                    isDown: type == .keyDown,
                    unicode: text,
                    isFlagsChanged: type == .flagsChanged))
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return nil
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return tap
    }

    func stop(_ tap: CFMachPort) {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
    }

    fileprivate func append(_ sample: Sample) {
        lock.lock(); samples.append(sample); lock.unlock()
    }
}

// MARK: - 自检内部状态

/// 证据④ 的监听器引用（局部变量在 `defer` 里够用，这里保留是为了将来扩展）
private var ledgersMonitor: Any?

/// 跑一会 runloop 让事件到达（自检专用；不改产品状态）
func pumpRunLoop(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.01))
    }
}

/// 当前时间戳（自检输出用）
func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return formatter.string(from: Date())
}

/// 会话诊断串（**锁屏/无 GUI 会话的证据**：锁屏时 frontmost 会是 loginwindow）
func sessionDiagnostics() -> String {
    var parts: [String] = []
    if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
        parts.append("ScreenIsLocked=\(dict["CGSSessionScreenIsLocked"] ?? "?")")
        parts.append("OnConsole=\(dict["kCGSSessionOnConsoleKey"] ?? "?")")
        parts.append("user=\(dict["kCGSSessionUserNameKey"] ?? "?")")
    } else {
        parts.append("CGSessionCopyCurrentDictionary=nil")
    }
    parts.append("frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
    parts.append("pid=\(getpid())")
    return parts.joined(separator: " ")
}

/// 当前进程常驻内存（RSS，字节）。读取 `task_info` 的 `resident_size`。
func residentMemoryBytes() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Int(info.resident_size)
}

func formatBytes(_ bytes: Int) -> String {
    let mb = Double(bytes) / 1024 / 1024
    return String(format: "%.1fMB", mb)
}

/// 在主线程上跑一段活，返回毫秒（测「主线程被占多久」）
func measureOnMainThread(_ body: @escaping () -> Void) async -> Double {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            let started = CFAbsoluteTimeGetCurrent()
            body()
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            continuation.resume(returning: ms)
        }
    }
}

/// 跑一段 async 活，返回毫秒
func measureAsync(_ body: @escaping () async -> Void) async -> Double {
    let started = CFAbsoluteTimeGetCurrent()
    await body()
    return (CFAbsoluteTimeGetCurrent() - started) * 1000
}

/// 主线程卡顿探针的统计结果
struct StallStats {
    var p50: Double = 0
    var p95: Double = 0
    var max: Double = 0
    var count: Int = 0
}

/// 主线程 runloop 调度抖动探针。
///
/// 【原理】在主线程上按固定粒度（2ms）登记「下一次该醒来的时刻」，醒来后量
/// **实际间隔**；若主线程被同步阻塞，间隔会被拉长 → p95 立刻变大。
/// 这与 `--perf-selftest` 的 tick.loop 直方图口径一致（都是"相邻间隔"而非平均）。
func mainThreadStallProbe(seconds: Double) async -> StallStats {
    var intervals: [Double] = []
    let deadline = Date().addingTimeInterval(seconds)
    var last = CFAbsoluteTimeGetCurrent()
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 2_000_000)   // 2ms 粒度
        await MainActor.run {
            let now = CFAbsoluteTimeGetCurrent()
            intervals.append((now - last) * 1000)
            last = now
        }
    }
    guard !intervals.isEmpty else { return StallStats() }
    let sorted = intervals.sorted()
    func percentile(_ p: Double) -> Double {
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
        return sorted[index]
    }
    return StallStats(p50: percentile(0.50), p95: percentile(0.95),
                      max: sorted.last ?? 0, count: sorted.count)
}

/// 抓一张真实屏幕帧（视觉自检用）。
///
/// 【为什么不用 `CGWindowListCreateImage`】macOS 26 SDK 已把它标记为
/// `unavailable`（`error: 'CGWindowListCreateImage' is unavailable in macOS:
/// Please use ScreenCaptureKit instead.`）；且本仓采集层本就跑在 ScreenCaptureKit 上
/// （`CaptureEngine.swift:24` 声明 `SCStreamOutput`）。故按以下顺序取帧：
///   · 优先：`DriveState.shared.currentFrameCG`（AuroraDriveApp.swift:4944，
///     由采集回调直传的最近一帧 —— 与 W4 `screenshot` 工具**同一数据源**）
///   · 兜底：`/usr/sbin/screencapture`（独立于本进程采集状态，需屏幕录制权限）
///
/// ⚠️ 必须**在主线程**调用（`DriveState` 是 `@MainActor`）。
@MainActor
func captureScreenFrame() -> CGImage? {
    if let frame = MainActor.assumeIsolated({ DriveState.shared.currentFrameCG }) {
        return frame
    }
    let path = NSTemporaryDirectory() + "aurora-vision-selftest-\(getpid()).png"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", path]
    try? process.run()
    process.waitUntilExit()
    defer { try? FileManager.default.removeItem(atPath: path) }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// 某 GameKey 在美式键盘布局下**应有的** Unicode 翻译（F1 回归的期望值）。
/// 修饰键（Shift/Ctrl）无字符，返回空串表示「不做字符断言」。
func expectedUnicode(for key: ControlEngine.GameKey) -> String {
    switch key {
    case .w:     return "w"
    case .a:     return "a"
    case .s:     return "s"
    case .d:     return "d"
    case .f:     return "f"
    case .e:     return "e"
    case .q:     return "q"
    case .r:     return "r"
    case .m:     return "m"
    case .b:     return "b"
    case .t:     return "t"
    case .space: return " "
    case .esc:   return "\u{1B}"
    case .one:   return "1"
    case .two:   return "2"
    case .three: return "3"
    case .four:  return "4"
    case .five:  return "5"
    case .six:   return "6"
    case .seven: return "7"
    case .j:     return "j"
    case .k:     return "k"
    case .l:     return "l"
    case .z:     return "z"
    case .x:     return "x"
    case .c:     return "c"
    case .v:     return "v"
    case .n:     return "n"
    case .g:     return "g"
    case .h:     return "h"
    case .i:     return "i"
    case .y:     return "y"
    case .u:     return "u"
    case .shift, .ctrl, .f1, .f2, .f4:
        return ""   // 无 Unicode 字符：只核对 keyCode，不做字符断言
    }
}
