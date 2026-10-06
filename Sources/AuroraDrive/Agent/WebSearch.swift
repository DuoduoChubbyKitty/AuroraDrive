// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  WebSearch.swift — AI 助手联网搜索工具（W5）
// ============================================================================
//
//  【目标】给 AI 助手（A3 自主调工具）提供两个只读工具：
//     · search(query:maxResults:)  —— 联网搜索，返回 [{title, url, snippet, source}]
//     · fetch(url:maxCharacters:)   —— 抓公开网页正文并转纯文本
//
//  【2026-10-06 本机实测渠道结论（不是推测，逐条有命令有原始输出）】
//    ① DuckDuckGo Lite  · POST https://lite.duckduckgo.com/lite/   → HTTP 200 / 23780 B / 10 条 result-link ✓
//       DDG 的 GET 与 POST 都接受：**首个请求 200，之后同一出口 IP 迅速被 403 限流**
//       （实测：GET 200 → 后续 6 次 GET 全 403；等待 45s 仍 403；换 POST 也 403）。
//       403 响应体只有 236 B：`If this persists, please <a href="mailto:error-lite+XXXX@duckduckgo.com?...">`
//       —— `error-lite+` 是该页面的**指纹**，本文件用它做精确的「被反爬拦截」识别。
//       ⚠️ 因此本实现**不做重试**：立刻退到 Wikipedia，而不是猛敲 DDG 把自己越敲越黑。
//    ② DuckDuckGo HTML  · https://html.duckduckgo.com/html/?q=  → 首次 HTTP 200 / 30190 B / 10 条结果 ✓
//       （`https://duckduckgo.com/html/` 是 302 跳转到它的）。⇒ 作为 DDG Lite 之后的第二档主力。
//    ③ Wikipedia MediaWiki API · https://zh.wikipedia.org/w/api.php?action=query&list=search
//       → 200，中文查询 11847 命中、英文 8358 命中，**带 snippet 正文摘要** ✓ 免 key、无限流。
//       （另实测 `action=opensearch` 与 REST `/api/rest_v1/page/summary/<title>` 同样免 key 可用。）
//    ④ ❌ SearXNG 公共实例（searx.be）：返回反爬验证页，不是 JSON
//    ⑤ ❌ Pollinations `:search` 模型：要 key
//    ⑥ ❌ Mojeek（www.mojeek.com/search）：返回 `<title>Captcha</title>` 验证页
//    ⑦ ❌ api.duckduckgo.com（Instant Answer JSON）：免 key 但**日常查询全是空结果**
//       （q=swift+actor → Abstract/Results/RelatedTopics 全空），不能当搜索用
//    ⑧ 本机出网环境：系统级代理 127.0.0.1:12450（scutil --proxy 实测），
//       Foundation 的 URLSession 默认读取系统代理设置 → 无需在代码里配置代理。
//       合规红线：**不使用代理池**，上面的代理是本机系统代理，不是翻墙手段。
//
//  【合规】只读公开网页。不绕验证码、不模拟登录、不提交表单以外的任何写操作、
//          不伪造 Referer 去骗过反爬、不轮换代理池。被拦就如实报错。
//
//  【诚实红线】任何失败一律抛 `WebSearchError`，**绝不返回占位/编造的结果**。
//          搜不到 = `.emptyResults`，被拦 = `.blocked`，超时 = `.timeout`（三者在 UI 上要能区分）。
//
//  【性能】全 async；独立 URLSession（不与 captureQueue / aurora.quest.ocr 共用）；
//          单次搜索硬超时 20s、fetch 硬超时 15s（TaskGroup 竞速，超时真的 cancel
//          底层请求，不留悬挂连接）；无任何主线程工作。
//          实测（2026-10-06，本机）：`search()` 端到端 **1062–1227 ms / 5 条结果**。
//
//  【自检】`swift run AuroraDrive --websearch-selftest ["查询词"] [--network]`
//          · 默认离线：解析器 + HTML 转文本 + 跳转解包 + Wikipedia JSON，全部用**实测原始 HTML 夹具**
//          · --network：真的发一次搜索 + 一次 fetch，把真实结果条数打印出来
//          ⚠️ 入口需在 AuroraDriveApp.swift 的 oneShotFlags 登记（由 W8 统一接线）。
//
//  【对外接口冻结】W4（ToolRegistry）按以下签名挂 web_search / web_fetch：
//      WebSearch.shared.search(query:maxResults:)  -> [SearchResult]
//      WebSearch.shared.fetch(url:maxCharacters:)  -> String
// ============================================================================

import Foundation
import CoreFoundation   // GB18030 解码（中文页常见编码）
import os

// ============================================================================
// MARK: - 数据模型
// ============================================================================

/// 单条搜索结果。
///
/// `source` 是**来源标注**，如实告诉调用方这条结果从哪条渠道来：
///   · "duckduckgo-lite"       DDG Lite POST 成功
///   · "duckduckgo-lite-get"   DDG Lite GET 成功
///   · "duckduckgo-html"       DDG html 端点成功（lite 之后的第二档）
///   · "wikipedia"             Wikipedia MediaWiki API 兜底（**不是全网搜索，是百科条目**）
/// UI / 模型据此能区分「全网结果」和「百科兜底」，不会把百科当成搜索骗用户。
public struct SearchResult: Sendable, Codable, Equatable {
    public let title: String
    public let url: String
    public let snippet: String
    public let source: String

    public init(title: String, url: String, snippet: String, source: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.source = source
    }
}

/// 联网失败的错误分类。**每一类都对应一次真实的实测观察**，绝不合并成一句"失败了"。
public enum WebSearchError: Error, LocalizedError, Sendable {
    /// 查询词为空/全空白
    case invalidQuery(String)
    /// URL 非法或不是 http(s)
    case invalidURL(String)
    /// 被反爬/验证码/限流页拦下（DDG 403 的 `error-lite+`、Mojeek 的 Captcha 页等）
    case blocked(statusCode: Int, reason: String)
    /// 本地限流冷却中（连续被拦后主动停手，避免把出口 IP 越敲越黑）
    case rateLimited(retryAfterSeconds: Int, reason: String)
    /// 其它 HTTP 错误状态码
    case http(statusCode: Int, url: String)
    /// 硬超时
    case timeout(url: String, seconds: Double)
    /// 传输层错误（DNS/连接/断网）
    case network(String)
    /// 拿到了响应但解析不出结构（改版）
    case parseFailed(String)
    /// 所有渠道都跑完，一条结果都没有 —— 如实说"没搜到"，不编
    case emptyResults(query: String, triedSources: [String])
    /// `fetch(url:)` 拿到的不是文本（图片/二进制）
    case unsupportedContent(contentType: String, url: String)

    public var errorDescription: String? {
        switch self {
        case .invalidQuery(let q):
            return "搜索词为空或非法：\(q.isEmpty ? "(空)" : q)"
        case .invalidURL(let u):
            return "URL 非法（只支持 http/https）：\(u)"
        case .blocked(let code, let reason):
            return "被目标站点反爬拦截（HTTP \(code)）：\(reason)。本工具不绕验证码、不模拟登录，已如实停止。"
        case .rateLimited(let secs, let reason):
            return "本地限流冷却中，还需 \(secs)s：\(reason)。这是为了避免连续请求把出口 IP 打进黑名单。"
        case .http(let code, let url):
            return "HTTP \(code)：\(url)"
        case .timeout(let url, let secs):
            return "请求超时（\(Int(secs))s 硬超时）：\(url)"
        case .network(let msg):
            return "网络错误：\(msg)"
        case .parseFailed(let msg):
            return "响应解析失败（站点可能改版）：\(msg)"
        case .emptyResults(let q, let tried):
            return "没有搜到「\(q)」的结果（已尝试渠道：\(tried.joined(separator: " → "))）。"
        case .unsupportedContent(let ct, let url):
            return "内容不是文本（\(ct)），拒绝当正文返回：\(url)"
        }
    }

    /// 「这条失败是渠道问题还是查询问题」—— 给模型看的短标签，避免它把渠道挂掉理解成"世界不存在"
    public var kindLabel: String {
        switch self {
        case .invalidQuery, .invalidURL:        return "参数错误"
        case .blocked, .rateLimited:            return "渠道被限流"
        case .timeout:                          return "请求超时"
        case .network:                          return "网络不可达"
        case .http, .parseFailed:               return "渠道异常"
        case .emptyResults:                     return "无结果"
        case .unsupportedContent:               return "内容非文本"
        }
    }
}

// ============================================================================
// MARK: - 内部：限流冷却（actor 私有状态）
// ============================================================================

/// 出口限流状态：连续被拦就主动停手一段时间。
///
/// 【为什么要有】实测 DDG 的限流是**按出口 IP** 的：一旦被 403，继续请求只会
/// 反复吃 403（实测等 45s 仍 403）。继续敲毫无收益，还会加深封禁。
/// 所以策略是：连续 2 次被拦 → 冷却 90s → 冷却期内**直接抛 `.rateLimited`**
/// （附带剩余秒数），让模型/用户知道"是限流不是没结果"。
struct WebSearchThrottle: Sendable {
    var consecutiveBlocks: Int = 0
    var cooldownUntil: Date?
    /// 冷却时长（秒）。环境变量 `AURORA_WEBSEARCH_COOLDOWN` 可覆盖。
    var cooldownSeconds: Double = 90

    init() {
        if let raw = ProcessInfo.processInfo.environment["AURORA_WEBSEARCH_COOLDOWN"],
           let v = Double(raw), v >= 0 {
            cooldownSeconds = v
        }
    }

    /// 冷却剩余秒数（0 = 不在冷却）
    func remainingCooldown(now: Date = Date()) -> Int {
        guard let until = cooldownUntil else { return 0 }
        let left = Int(until.timeIntervalSince(now).rounded(.up))
        return max(0, left)
    }

    mutating func noteBlocked() {
        consecutiveBlocks += 1
        if consecutiveBlocks >= 2 {
            cooldownUntil = Date().addingTimeInterval(cooldownSeconds)
        }
    }

    mutating func noteSuccess() {
        consecutiveBlocks = 0
        cooldownUntil = nil
    }
}

// ============================================================================
// MARK: - 主类型
// ============================================================================

/// 联网搜索 / 网页正文抓取（actor：串行化 + 保护内部限流状态）。
///
/// 全 async、无主线程工作；外部只用 `WebSearch.shared`。
/// 纯解析函数一律 `nonisolated static`，便于 W8 离线自检不碰网络。
public actor WebSearch {

    public static let shared = WebSearch()

    // ── 可调参数（全部有实测依据，见文件头）──
    /// 单次搜索硬超时（秒）。task-5 要求 ≤20s。
    static let searchTimeout: Double = 20
    /// fetch 硬超时（秒）。task-5 要求 15s。
    static let fetchTimeout: Double = 15
    /// fetch 默认返回长度上限（字符）。
    /// ⚠️ 必须 `public`：它被用作 `fetch(url:maxCharacters:)` 的默认参数值，
    /// internal 常量不能出现在 public 函数的默认实参里（实测编译报错
    /// `static property ... is internal and cannot be referenced from a default argument value`）。
    public static let defaultFetchCharacters = 8000
    /// 单工具体积上限：一次搜索最多回给模型的正文（防止把上下文冲爆）
    static let maxResponseBytes = 2 * 1024 * 1024

    /// 常规浏览器 UA。DDG 对无 UA 的请求（如 curl/8.7.1）直接 403（实测）。
    static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private var throttle = WebSearchThrottle()

    /// 独立 URLSession：**不与 captureQueue / quest OCR 共用**（性能红线）。
    /// ephemeral = 不落盘缓存；cookie 存储独立且内存内，DDG 的 POST 表单流需要它。
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20          // 与硬超时一致（兜底）
        cfg.timeoutIntervalForResource = 25
        cfg.waitsForConnectivity = false            // 断网立刻失败，不静默等待
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 不用 `httpShouldUsePipelining`：macOS 15.4 起已废弃（实测 deprecation 警告），
        // 而 HTTP/2 连接本身就是复用的，不需要它。
        cfg.httpAdditionalHeaders = [
            "User-Agent": WebSearch.browserUA,
            // 只声明语言偏好（正常浏览器都发），不伪造 Referer 去骗反爬
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ]
        return URLSession(configuration: cfg)
    }()

    private let log = Logger(subsystem: "com.aurora.drive", category: "websearch")

    // ========================================================================
    // MARK: - 对外：search
    // ========================================================================

    /// 联网搜索。
    ///
    /// 渠道顺序（**照实测结论**，失败即降级并如实标注 source）：
    ///   ① DDG Lite **POST /lite/**（表单流是实测唯一稳定拿到 200 的形态）
    ///   ② DDG Lite GET（POST 被拦时换个形态再试一次）
    ///   ③ DDG html 端点（html.duckduckgo.com/html/，独立限流桶）
    ///   ④ Wikipedia MediaWiki API（**百科兜底**，source 标 "wikipedia" 让调用方知情）
    ///
    /// ⚠️ ①→③ 之间**不重试同一条渠道**（实测重试无收益），④ 之后仍为空则抛 `.emptyResults`。
    public func search(query: String, maxResults: Int = 5) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebSearchError.invalidQuery(query) }
        let limit = max(1, min(maxResults, 20))

        // 冷却期内直接如实拒绝，不打网络
        let cooldown = throttle.remainingCooldown()
        if cooldown > 0 {
            throw WebSearchError.rateLimited(
                retryAfterSeconds: cooldown,
                reason: "连续 \(throttle.consecutiveBlocks) 次被 DuckDuckGo 反爬拦截（HTTP 403）")
        }

        var tried: [String] = []
        var firstError: WebSearchError?

        // ── ① DDG Lite POST ──
        tried.append("duckduckgo-lite-post")
        do {
            let html = try await ddgLiteRequest(query: trimmed, usePOST: true)
            let hits = Self.parseDuckDuckGoLite(html: html, maxResults: limit)
            if !hits.isEmpty {
                throttle.noteSuccess()
                return hits.map { SearchResult(title: $0.title, url: $0.url, snippet: $0.snippet,
                                               source: "duckduckgo-lite") }
            }
            log.warning("DDG Lite POST 返回 200 但解析出 0 条（改版?）bytes=\(html.count)")
        } catch let e as WebSearchError {
            firstError = firstError ?? e
            if case .blocked = e { throttle.noteBlocked() }
        }

        // ── ② DDG Lite GET ──
        tried.append("duckduckgo-lite-get")
        do {
            let html = try await ddgLiteRequest(query: trimmed, usePOST: false)
            let hits = Self.parseDuckDuckGoLite(html: html, maxResults: limit)
            if !hits.isEmpty {
                throttle.noteSuccess()
                return hits.map { SearchResult(title: $0.title, url: $0.url, snippet: $0.snippet,
                                               source: "duckduckgo-lite-get") }
            }
        } catch let e as WebSearchError {
            firstError = firstError ?? e
            if case .blocked = e { throttle.noteBlocked() }
        }

        // ── ③ DDG html 端点（不同路径 → 独立限流桶，实测首请求可过）──
        tried.append("duckduckgo-html")
        do {
            let html = try await httpGetText(
                urlString: "https://html.duckduckgo.com/html/?q=\(Self.percentEncodeQuery(trimmed))",
                referer: nil,
                timeout: Self.searchTimeout)
            let hits = Self.parseDuckDuckGoHTML(html: html, maxResults: limit)
            if !hits.isEmpty {
                throttle.noteSuccess()
                return hits.map { SearchResult(title: $0.title, url: $0.url, snippet: $0.snippet,
                                               source: "duckduckgo-html") }
            }
        } catch let e as WebSearchError {
            firstError = firstError ?? e
            if case .blocked = e { throttle.noteBlocked() }
        }

        // ── ④ Wikipedia 兜底（如实标注 source=wikipedia）──
        tried.append("wikipedia")
        do {
            let hits = try await wikipediaSearch(query: trimmed, maxResults: limit)
            if !hits.isEmpty {
                throttle.noteSuccess()   // 兜底成功也算"网络是通的"，清掉 DDG 的连击计数
                return hits
            }
        } catch let e as WebSearchError {
            firstError = firstError ?? e
        }

        // 全渠道都没结果 —— 如实抛。绝不返回占位数据。
        if let blockedFirst = firstError, case .blocked = blockedFirst {
            throw blockedFirst
        }
        throw WebSearchError.emptyResults(query: trimmed, triedSources: tried)
    }

    // ========================================================================
    // MARK: - 对外：fetch
    // ========================================================================

    /// 抓公开网页正文，转纯文本（去 script/style/标签、解实体、压空白），截断到 `maxCharacters`。
    ///
    /// - 只接受 http/https；非文本 Content-Type 抛 `.unsupportedContent`（不把二进制当正文）。
    /// - 硬超时 15s。失败如实抛错。
    public func fetch(url: String, maxCharacters: Int = WebSearch.defaultFetchCharacters) async throws -> String {
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: raw),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw WebSearchError.invalidURL(url)
        }
        let limit = max(1, maxCharacters)
        let (data, contentType) = try await httpGetData(url: parsed, referer: nil, timeout: Self.fetchTimeout)

        // 只认文本。图片/PDF/二进制一律拒绝，避免把乱码当正文喂给模型。
        let ct = contentType.lowercased()
        let isText = ct.isEmpty || ct.hasPrefix("text/") || ct.contains("json")
            || ct.contains("xml") || ct.contains("xhtml") || ct.contains("javascript")
        guard isText else {
            throw WebSearchError.unsupportedContent(contentType: contentType, url: raw)
        }

        guard let html = Self.decodeBody(data) else {
            throw WebSearchError.parseFailed("无法解码响应体（UTF-8/GB18030 都失败，\(data.count) B）")
        }
        let text = Self.plainText(fromHTML: html, maxCharacters: limit)
        guard !text.isEmpty else {
            throw WebSearchError.parseFailed("正文提取后为空：\(raw)")
        }
        return text
    }

    // ========================================================================
    // MARK: - 网络底层（全部 async，无主线程工作）
    // ========================================================================

    /// DDG Lite 请求（POST 表单 / GET query），返回 HTML 文本。
    /// 403 + `error-lite+` 指纹 → `.blocked`（实测该指纹只出现在反爬拦截页上）。
    private func ddgLiteRequest(query: String, usePOST: Bool) async throws -> String {
        var request: URLRequest
        if usePOST {
            guard let url = URL(string: "https://lite.duckduckgo.com/lite/") else {
                throw WebSearchError.invalidURL("https://lite.duckduckgo.com/lite/")
            }
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            // 表单体：q=<percent-encoded>（实测 curl --data-urlencode 的成功形态）
            request.httpBody = Data("q=\(Self.percentEncodeQuery(query))".utf8)
        } else {
            guard let url = URL(string: "https://lite.duckduckgo.com/lite/?q=\(Self.percentEncodeQuery(query))") else {
                throw WebSearchError.invalidURL("https://lite.duckduckgo.com/lite/")
            }
            request = URLRequest(url: url)
        }
        request.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")

        // ⚠️ 先固化 URL 字符串再进并发闭包：闭包内若再读 `request`（var）会报
        //    "reference to captured var in concurrently-executing code"（Swift 6 下是 error）。
        let requestURL = request.url?.absoluteString ?? "https://lite.duckduckgo.com/lite/"
        let frozen = request      // 转成 let 快照
        return try await withHardTimeout(seconds: Self.searchTimeout, url: requestURL) {
            let (data, response) = try await self.session.data(for: frozen)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            let body = Self.decodeBody(data) ?? ""

            if code == 403 || Self.looksLikeBlockPage(body) {
                throw WebSearchError.blocked(
                    statusCode: code == 0 ? 403 : code,
                    reason: Self.blockReason(from: body, code: code))
            }
            guard (200...299).contains(code) else {
                throw WebSearchError.http(statusCode: code, url: requestURL)
            }
            return body
        }
    }

    /// 通用 GET（文本）
    private func httpGetText(urlString: String, referer: String?, timeout: Double) async throws -> String {
        guard let url = URL(string: urlString) else { throw WebSearchError.invalidURL(urlString) }
        let (data, _) = try await httpGetData(url: url, referer: referer, timeout: timeout)
        guard let text = Self.decodeBody(data) else {
            throw WebSearchError.parseFailed("无法解码响应体（\(data.count) B）")
        }
        return text
    }

    /// 通用 GET（原始字节 + Content-Type）
    private func httpGetData(url: URL, referer: String?, timeout: Double) async throws -> (Data, String) {
        var request = URLRequest(url: url)
        request.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        let frozen = request      // let 快照：并发闭包捕获 var 在 Swift 6 下是 error
        let requestURL = url.absoluteString

        return try await withHardTimeout(seconds: timeout, url: requestURL) {
            let (data, response) = try await self.session.data(for: frozen)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            let ct = http?.value(forHTTPHeaderField: "Content-Type") ?? ""

            if code == 403 || code == 429 {
                let body = Self.decodeBody(data) ?? ""
                throw WebSearchError.blocked(
                    statusCode: code,
                    reason: Self.blockReason(from: body, code: code))
            }
            guard (200...299).contains(code) else {
                throw WebSearchError.http(statusCode: code, url: requestURL)
            }
            guard data.count <= Self.maxResponseBytes else {
                throw WebSearchError.parseFailed("响应体过大（\(data.count) B > \(Self.maxResponseBytes) B），拒绝加载")
            }
            return (data, ct)
        }
    }

    /// 竞速结果。**故意让两个子任务都不 throws**。
    ///
    /// 【为什么不能直接 `try await group.next()` + 子任务里 throw 超时】
    /// `withThrowingTaskGroup` 在 body 正常返回后，会**隐式 await 剩余子任务**：
    /// 只要还有任何一个子任务抛了错，这个错就会**替换掉 body 的返回值**被重新抛出。
    /// 于是「请求已经成功、超时哨兵随后被 cancel」这条正常路径，会因为哨兵抛
    /// `WebSearchError.timeout`（或 cancel 引发的 CancellationError）而**把成功结果吃掉、
    /// 反向报成超时**。所以哨兵只返回 `.timeout`，绝不抛错；真正的错误在 `.failure` 里携带。
    private enum RaceOutcome<T: Sendable>: Sendable {
        case value(T)
        case failure(WebSearchError)
        case timeout
    }

    /// 硬超时：竞速，「谁先完成用谁」，超时即 cancel 子任务
    /// （URLSession 的 async API 响应取消 → 不留悬挂连接）。
    private func withHardTimeout<T: Sendable>(
        seconds: Double,
        url: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let outcome = await withTaskGroup(of: RaceOutcome<T>.self) { group in
            group.addTask {
                do {
                    return .value(try await operation())
                } catch {
                    // 立刻归一化成 Sendable 的 WebSearchError（不把 any Error 带出隔离域）
                    return .failure(Self.normalize(error: error, url: url, seconds: seconds))
                }
            }
            group.addTask {
                // 被 cancel 时 sleep 抛 CancellationError；`try?` 吞掉后仍返回 .timeout，
                // 但这个结果在成功路径上已经被丢弃，不会影响调用方。
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .timeout
            }
            guard let first = await group.next() else { return RaceOutcome<T>.timeout }
            group.cancelAll()          // 另一条分支立刻收手，不留悬挂连接
            return first
        }
        switch outcome {
        case .value(let v):   return v
        case .failure(let e): throw e
        case .timeout:        throw WebSearchError.timeout(url: url, seconds: seconds)
        }
    }

    /// 把任意 Error 归一化成 `WebSearchError`（**如实分类，不吞错**）。
    /// 断网 / DNS 失败 / 连接被拒 → `.network`；底层超时 → `.timeout`。
    nonisolated static func normalize(error: Error, url: String, seconds: Double) -> WebSearchError {
        if let e = error as? WebSearchError { return e }
        if error is CancellationError { return .network("请求被取消：\(url)") }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut:
                return .timeout(url: url, seconds: seconds)
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed, NSURLErrorSecureConnectionFailed,
                 NSURLErrorAppTransportSecurityRequiresSecureConnection,
                 NSURLErrorResourceUnavailable:
                return .network("\(ns.localizedDescription)（URLError \(ns.code)）")
            default:
                return .network("URLError \(ns.code)：\(ns.localizedDescription)")
            }
        }
        return .network("\(ns.domain) \(ns.code)：\(ns.localizedDescription)")
    }

    // ========================================================================
    // MARK: - Wikipedia 兜底
    // ========================================================================

    /// MediaWiki 搜索 API（免 key，实测可用，**带正文 snippet**）。
    /// 先中文维基；中文 0 命中再试英文维基（英文查询词在 zh 上命中率低）。
    /// ⚠️ 返回的 source 固定 "wikipedia" —— 这是**百科条目**，不是全网搜索，调用方必须知情。
    private func wikipediaSearch(query: String, maxResults: Int) async throws -> [SearchResult] {
        var lastError: WebSearchError?
        for lang in ["zh", "en"] {
            let urlString = "https://\(lang).wikipedia.org/w/api.php"
                + "?action=query&list=search&srsearch=\(Self.percentEncodeQuery(query))"
                + "&format=json&srlimit=\(maxResults)&utf8=1"
            do {
                let text = try await httpGetText(urlString: urlString, referer: nil, timeout: Self.searchTimeout)
                let hits = Self.parseWikipediaSearchJSON(text: text)
                if !hits.isEmpty { return hits }
            } catch let e as WebSearchError {
                lastError = lastError ?? e
            }
        }
        if let lastError { throw lastError }
        return []
    }

    // ========================================================================
    // MARK: - 纯解析（nonisolated static：W8 离线自检直接调，不碰网络）
    // ========================================================================

    /// HTML 实体解码：命名实体 + 十进制/十六进制数字实体。
    /// 实测 DDG 的标题里会出现 `&#x27;`（撇号）和 `&amp;`，摘要里还有 `<b>` 高亮标签。
    public nonisolated static func decodeHTMLEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "&", let semi = s[i...].firstIndex(of: ";"),
                  s.distance(from: i, to: semi) <= 12 else {
                out.append(c); i = s.index(after: i); continue
            }
            let body = String(s[s.index(after: i)..<semi])
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                if let code = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                    replacement = String(Character(scalar))
                }
            } else if body.hasPrefix("#") {
                if let code = UInt32(body.dropFirst()), let scalar = Unicode.Scalar(code) {
                    replacement = String(Character(scalar))
                }
            } else {
                switch body.lowercased() {
                case "amp":    replacement = "&"
                case "lt":     replacement = "<"
                case "gt":     replacement = ">"
                case "quot":   replacement = "\""
                case "apos":   replacement = "'"
                case "nbsp":   replacement = " "
                case "hellip": replacement = "…"
                case "mdash":  replacement = "—"
                case "ndash":  replacement = "–"
                case "middot": replacement = "·"
                case "ensp", "emsp", "thinsp": replacement = " "
                default:       replacement = nil
                }
            }
            if let r = replacement {
                out.append(r); i = s.index(after: semi)
            } else {
                out.append(c); i = s.index(after: i)     // 不认识的实体原样保留（别乱吃字符）
            }
        }
        return out
    }

    /// 去掉所有标签（`<...>`），并解 HTM 实体。注意：不处理 `<` 作为普通文本的情况
    /// （搜索结果里不会出现），保证行为可预测。
    public nonisolated static func stripTags(_ html: String) -> String {
        var out = ""
        out.reserveCapacity(html.count)
        var inTag = false
        for ch in html {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        return decodeHTMLEntities(out)
    }

    /// 解 DDG 的跳转包装：
    ///   `//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1&rut=...`
    ///   → `https://example.com/a?b=1`
    /// 已经是直链的（`https://...`）原样返回；不是 http(s) 的返回 nil（调用方丢弃，别把伪协议喂给 fetch）。
    public nonisolated static func decodeDuckDuckGoRedirect(href: String) -> String? {
        let raw = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        var candidate = raw
        // 只有带 uddg 参数的才是包装链接
        if raw.contains("uddg=") {
            guard let value = queryValue(named: "uddg", in: raw) else { return nil }
            // ① 先纯 percent-decode（DDG 的正规形态：空格是 %20）
            if let decoded = value.removingPercentEncoding, isHTTP(decoded) { return decoded }
            // ② 兜底：有些形态用 `+` 当空格，再解一次
            let plusDecoded = value.replacingOccurrences(of: "+", with: " ")
            if let decoded = plusDecoded.removingPercentEncoding, isHTTP(decoded) { return decoded }
            if isHTTP(value) { return value }
            return nil
        }

        // 协议相对链接（//host/path）补 https
        if candidate.hasPrefix("//") { candidate = "https:" + candidate }
        return isHTTP(candidate) ? candidate : nil
    }

    /// 从 query string 里取参数（**不用** URLComponents：uddg 的值本身是 URL，
    /// 某些形态下 URLComponents 会把它的 `&`/`?` 吃掉）。
    public nonisolated static func queryValue(named name: String, in urlString: String) -> String? {
        guard let qIndex = urlString.firstIndex(of: "?") else { return nil }
        let query = urlString[urlString.index(after: qIndex)...]
        for pair in query.split(separator: "&") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[pair.startIndex..<eq])
            if key == name {
                return String(pair[pair.index(after: eq)...])
            }
        }
        return nil
    }

    private nonisolated static func isHTTP(_ s: String) -> Bool {
        let low = s.lowercased()
        return low.hasPrefix("http://") || low.hasPrefix("https://")
    }

    /// 查询词 percent 编码。
    ///
    /// 【2026-10-06 实测校准 —— 推翻了我一开始的假设】本机 `swiftc` 跑最小样例逐字输出：
    ///   `"异环 攻略".addingPercentEncoding(withAllowedCharacters: 字母数字+`-._~`)`
    ///   → `%E5%BC%82%E7%8E%AF%20%E6%94%BB%E7%95%A5` —— **就是正确的 UTF-8 编码**，
    ///   中文不会退化成 `%3F`。所以直接用标准 API 即可，不需要（也无法）额外指定编码：
    ///   本 SDK 上该 API **没有** `basedOn:` 形态，多写这个参数直接编译不过
    ///   （实测 `error: extra argument 'basedOn' in call`，已据此改正）。
    ///
    /// 【仍然必须自定义字符集】**不能用 `.urlQueryAllowed`**：它放过 `&` `+` `=` `?` `/`，
    /// 查询词里带这些字符会把 query string 拆坏（`A&B` 会被服务端当成两个参数）。
    /// 这里用「字母数字 + `-._~`」白名单（RFC 3986 unreserved），空格编成 `%20`。
    public nonisolated static func percentEncodeQuery(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// 反爬/验证码页识别（实测指纹）：
    ///   · DDG 403：`error-lite+` / `Error getting results`（236 B 的极短页）
    ///   · Mojeek：`<title>Captcha</title>`
    ///   · 通用：`captcha` / `are you a robot` / `unusual traffic` / `cf-challenge`
    public nonisolated static func looksLikeBlockPage(_ body: String) -> Bool {
        if body.count < 700 {
            let low = body.lowercased()
            if low.contains("error-lite+") { return true }
            if low.contains("error getting results") { return true }
        }
        let low = body.lowercased()
        let fingerprints = ["captcha", "are you a robot", "unusual traffic",
                            "cf-challenge", "checking your browser"]
        // 只在前 4000 字符里找指纹（避免正文里恰好提到 captcha 就误判）
        let head = String(low.prefix(4000))
        return fingerprints.contains { head.contains($0) }
    }

    /// 从响应体构造人类可读的拦截原因
    public nonisolated static func blockReason(from body: String, code: Int) -> String {
        let low = body.lowercased()
        if low.contains("error-lite+") || low.contains("error getting results") {
            return "DuckDuckGo 反爬页（error-lite 错误码），通常因同 IP 短时间请求过多"
        }
        if low.contains("captcha") { return "站点返回验证码页（不绕验证码）" }
        if code == 429 { return "HTTP 429 限流" }
        return "HTTP \(code)"
    }

    // ── 解析 DDG Lite（表格结构，实测原文见 runSelfTest 里的夹具）──

    /// 解析 `https://lite.duckduckgo.com/lite/` 的结果表。
    ///
    /// 实测结构（2026-10-06 原始 HTML）：
    /// ```
    ///   <td>
    ///     <a rel="nofollow" href="https://developer.apple.com/documentation/swift/actor"
    ///        class='result-link'>Actor | Apple Developer Documentation</a>
    ///   </td>
    /// </tr>
    /// <tr>
    ///   <td>&nbsp;&nbsp;&nbsp;</td>
    ///   <td class='result-snippet'>
    ///     Overview The <b>Actor</b> protocol generalizes ...
    ///   </td>
    /// </tr>
    /// ```
    /// 即：**标题锚点在下、摘要在紧随其后的 `result-snippet` 单元格里**。
    public nonisolated static func parseDuckDuckGoLite(html: String, maxResults: Int) -> [SearchResult] {
        parseAnchors(html: html, maxResults: maxResults,
                     linkClassNeedles: ["result-link"],
                     snippetClassNeedles: ["result-snippet"],
                     source: "duckduckgo-lite")
    }

    /// 解析 `https://html.duckduckgo.com/html/` 的结果（class="result__a" / "result__snippet"）。
    public nonisolated static func parseDuckDuckGoHTML(html: String, maxResults: Int) -> [SearchResult] {
        parseAnchors(html: html, maxResults: maxResults,
                     linkClassNeedles: ["result__a"],
                     snippetClassNeedles: ["result__snippet"],
                     source: "duckduckgo-html")
    }

    /// 两个 DDG 端点共用的解析器：扫 `<a ...>` 锚点，按 class 命中链接，
    /// 再从锚点位置往后找最近的摘要单元格。
    nonisolated static func parseAnchors(
        html: String,
        maxResults: Int,
        linkClassNeedles: [String],
        snippetClassNeedles: [String],
        source: String
    ) -> [SearchResult] {
        var results: [SearchResult] = []
        var seenURLs = Set<String>()
        var cursor = html.startIndex

        while results.count < maxResults, cursor < html.endIndex,
              let lt = html[cursor...].firstIndex(of: "<") {
            // 只处理锚点开标签
            guard html[lt...].hasPrefix("<a") || html[lt...].hasPrefix("<A"),
                  let gt = html[lt...].firstIndex(of: ">") else {
                cursor = html.index(after: lt)
                continue
            }
            let tag = String(html[lt...gt])
            cursor = html.index(after: gt)

            // class 必须命中（`class='result-link'` / `class="result__a"` 两种引号都要认）
            let tagLower = tag.lowercased()
            guard linkClassNeedles.contains(where: { tagLower.contains($0.lowercased()) }) else { continue }

            guard let href = attributeValue(named: "href", in: tag),
                  let url = decodeDuckDuckGoRedirect(href: href) else { continue }

            // 锚点文本 = 标题；到下一个 `</a>` 为止
            let innerEnd = html[cursor...].range(of: "</a>")?.lowerBound ?? html.endIndex
            let title = stripTags(String(html[cursor..<innerEnd])).collapsedWhitespace()
            cursor = innerEnd

            // 摘要：从锚点之后往后找最近的 snippet 单元格（最多向后看 4000 字符，
            // 避免跨条串味 —— 实测每个摘要紧跟在标题那一行之后）
            let windowEnd = html.index(cursor, offsetBy: min(4000, html.distance(from: cursor, to: html.endIndex)))
            let window = String(html[cursor..<windowEnd])
            let snippet = nearestSnippet(in: window, needles: snippetClassNeedles)

            guard !title.isEmpty, !url.isEmpty else { continue }
            guard !seenURLs.contains(url) else { continue }
            seenURLs.insert(url)

            results.append(SearchResult(title: title, url: url,
                                        snippet: snippet.isEmpty ? "(无摘要)" : snippet,
                                        source: source))
        }
        return results
    }

    /// 在窗口里找 `class="result-snippet"` 单元格的文本。
    nonisolated static func nearestSnippet(in window: String, needles: [String]) -> String {
        for needle in needles {
            // 在**原串**上大小写不敏感查找（不能 lowercased 后再用它的 range 索引原串 → 会错位）
            guard let r = window.range(of: needle, options: .caseInsensitive) else { continue }
            // 从 class 属性往后的下一个 `>` 开始，到该单元格的 `</td>` 或 `</a>` 结束
            guard let gt = window[r.upperBound...].firstIndex(of: ">") else { continue }
            let bodyStart = window.index(after: gt)
            let rest = window[bodyStart...]
            let end = rest.range(of: "</td>", options: .caseInsensitive)?.lowerBound
                ?? rest.range(of: "</a>", options: .caseInsensitive)?.lowerBound
                ?? rest.index(rest.startIndex, offsetBy: min(1200, rest.count))
            let text = stripTags(String(rest[rest.startIndex..<end])).collapsedWhitespace()
            if !text.isEmpty { return text }
        }
        return ""
    }

    /// 取开标签里的属性值，支持单/双引号与无引号三种形态。
    /// 例：`<a rel="nofollow" href="//duckduckgo.com/l/?uddg=..." class='result-link'>`
    ///
    /// ⚠️ 在**原串**上用 `.caseInsensitive` 查找 —— 不要先 `lowercased()` 再拿它的
    /// range 去索引原串：`lowercased()` 可能改变长度（如 "İ"），index 会错位甚至崩。
    public nonisolated static func attributeValue(named name: String, in tag: String) -> String? {
        var searchStart = tag.startIndex
        while searchStart < tag.endIndex,
              let r = tag.range(of: name, options: .caseInsensitive, range: searchStart..<tag.endIndex) {
            // 左边界必须是分隔符（别让 "href" 命中 "data-href"）
            let beforeOK: Bool
            if r.lowerBound == tag.startIndex {
                beforeOK = true
            } else {
                let before = tag[tag.index(before: r.lowerBound)]
                beforeOK = before == " " || before == "\t" || before == "\n" || before == "\r"
            }
            // 右边界必须是空白、`=` 或串尾（别让 "href" 命中 "hrefx"）
            let afterOK = r.upperBound == tag.endIndex
                || tag[r.upperBound] == "=" || tag[r.upperBound].isWhitespace

            guard beforeOK, afterOK else { searchStart = r.upperBound; continue }

            var i = r.upperBound
            while i < tag.endIndex, tag[i].isWhitespace { i = tag.index(after: i) }
            guard i < tag.endIndex, tag[i] == "=" else { searchStart = r.upperBound; continue }
            i = tag.index(after: i)
            while i < tag.endIndex, tag[i] == " " { i = tag.index(after: i) }
            guard i < tag.endIndex else { return nil }
            let quote = tag[i]
            if quote == "\"" || quote == "'" {
                let start = tag.index(after: i)
                guard let close = tag[start...].firstIndex(of: quote) else { return nil }
                return decodeHTMLEntities(String(tag[start..<close]))
            } else {
                let start = i
                var end = i
                while end < tag.endIndex, !tag[end].isWhitespace, tag[end] != ">" {
                    end = tag.index(after: end)
                }
                return decodeHTMLEntities(String(tag[start..<end]))
            }
        }
        return nil
    }

    // ── Wikipedia JSON ──

    /// 解析 MediaWiki `action=query&list=search` 的 JSON：
    /// `{"query":{"search":[{"title":"异环","snippet":"《<span class=\"searchmatch\">异</span>环》…"}]}}`
    /// snippet 里的 `<span class="searchmatch">` 高亮标签会被剥掉。
    /// 同时兼容 `action=opensearch` 的数组形态 `["q",[titles],[descs],[urls]]`（回退用）。
    public nonisolated static func parseWikipediaSearchJSON(text: String) -> [SearchResult] {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }

        // ① list=search 形态
        if let dict = obj as? [String: Any],
           let query = dict["query"] as? [String: Any],
           let arr = query["search"] as? [[String: Any]] {
            return arr.compactMap { item in
                guard let title = item["title"] as? String, !title.isEmpty else { return nil }
                let snippet = stripTags((item["snippet"] as? String) ?? "").collapsedWhitespace()
                let encoded = percentEncodeQuery(title.replacingOccurrences(of: " ", with: "_"))
                let url = "https://zh.wikipedia.org/wiki/\(encoded)"
                return SearchResult(title: title, url: url,
                                    snippet: snippet.isEmpty ? "(维基百科条目)" : snippet,
                                    source: "wikipedia")
            }
        }

        // ② opensearch 形态：[query, [titles], [descriptions], [urls]]
        if let arr = obj as? [Any], arr.count >= 4,
           let titles = arr[1] as? [String], let urls = arr[3] as? [String] {
            let descs = (arr[2] as? [String]) ?? []
            return titles.enumerated().compactMap { (i, title) in
                guard i < urls.count, !title.isEmpty else { return nil }
                let desc = i < descs.count ? descs[i] : ""
                return SearchResult(title: title, url: urls[i],
                                    snippet: desc.isEmpty ? "(维基百科条目)" : desc,
                                    source: "wikipedia")
            }
        }
        return []
    }

    // ── 正文提取 ──

    /// 把 HTML 变纯文本：
    ///   ① 删 `<!-- -->` 注释、`<script>`/`<style>`/`<noscript>`/`<svg>` 整块
    ///   ② 块级标签（p/div/br/li/h1-6/tr…）→ 换行；其余标签 → 空
    ///   ③ 解 HTML 实体
    ///   ④ 压空白（连续空格/Tab → 单空格；≥2 换行 → 2 换行）
    ///   ⑤ 截断到 `maxCharacters`（默认 8000，附件 ⑨ 的产物）
    public nonisolated static func plainText(fromHTML html: String, maxCharacters: Int) -> String {
        var s = html

        // ① 注释与脚本体。
        //    ⚠️ 元素名必须按**标签边界**匹配（`<head` 不能命中 `<header>`）——
        //    这正是 2026-10-06 实测抓到的 bug：维基百科页面里 `<head` 出现 3 次
        //    （真 head 1 次 + 两个 `<header` 元素），而 `</head>` 只有 1 次，
        //    于是 `("<head","</head>")` 这一刀从**第一个 `<header>` 一直删到文末**，
        //    106KB 正文瞬间没了，只剩 5 个字符「跳转到内容」。
        for element in ["head", "script", "style", "noscript", "svg", "iframe", "template"] {
            s = removeElement(in: s, name: element)
        }
        s = removeBlocks(in: s, open: "<!--", close: "-->")

        // ①a 删掉**语义上就不是正文**的区块：导航 / 侧栏 / 页脚 / 表单。
        //     实测（维基百科异环条目）：加这一刀后，正文从第 ~1500 字提前到第 ~350 字出现，
        //     前 300 字里的「移至侧栏/隐藏/操作/打印/导出」等界面词全部消失。
        //     这些都是 HTML5 语义标签，删它们不会碰到正文 —— 比"猜正文容器"安全得多。
        for element in ["nav", "aside", "footer", "form"] {
            s = removeElement(in: s, name: element)
        }

        // ①b 优先取"正文容器"：现代网页的导航/侧栏/页脚会淹没正文
        //     （实测维基百科页：不裁剪时前 3000 字全是「主菜单/移至侧栏/导航」；
        //      裁剪后前 3000 字直接是词条正文）。只认**明确的正文标记**，
        //      认不出就老实返回全文 —— 宁可多带噪声，也不猜错把正文删掉。
        if let main = extractMainContent(in: s) { s = main }

        // ② 块级标签 → 换行
        let blockTags = ["</p>", "</div>", "</li>", "</tr>", "</h1>", "</h2>", "</h3>",
                         "</h4>", "</h5>", "</h6>", "</section>", "</article>", "</header>",
                         "</footer>", "</nav>", "</blockquote>", "</pre>", "</table>",
                         "<br>", "<br/>", "<br />", "</ul>", "</ol>", "</dd>", "</dt>"]
        for tag in blockTags {
            s = s.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: "</td>", with: " ", options: .caseInsensitive)

        // ③ 剩下的标签全删 + 解实体
        s = stripTags(s)
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")   // NBSP

        // ④ 压空白
        s = s.collapsedWhitespace()

        // ⑤ 截断（在词边界附近截，避免半截词；中文没有空格，就直接硬截）
        if s.count > maxCharacters {
            let idx = s.index(s.startIndex, offsetBy: maxCharacters)
            s = String(s[s.startIndex..<idx]) + "\n…（正文已截断，共 \(s.count) 字符）"
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 尝试截出正文容器；认不出来返回 nil（调用方保留全文）。
    ///
    /// 【为什么保守】猜错正文容器 = 把正文删掉，比多带导航噪声严重得多。
    /// 所以只认**公认的正文语义标记**：`<main>`、`role="main"`、
    /// 或 id/class 恰为 content / main / article / post / entry-content 的元素。
    /// 用「取最长候选」而不是「取第一个」，避免命中页头里的同名小容器。
    /// 实测（2026-10-06，维基百科异环条目）：不裁剪时前 3000 字全是
    /// 「主菜单/移至侧栏/导航」；裁剪后前 3000 字直接是词条正文。
    nonisolated static func extractMainContent(in html: String) -> String? {
        var candidates: [String] = []

        // ① <main>...</main>（按嵌套配平取整块）
        if let r = html.range(of: "<main", options: .caseInsensitive),
           let block = balancedElement(in: html, from: r.lowerBound, name: "main") {
            candidates.append(block)
        }

        // ② role="main"
        if let r = html.range(of: "role=\"main\"", options: .caseInsensitive),
           let tagStart = html[..<r.lowerBound].lastIndex(of: "<") {
            // 该属性所在标签名未知，先试 div（最常见），再试其它
            for name in ["div", "main", "section", "article"] {
                if let block = balancedElement(in: html, from: tagStart, name: name) {
                    candidates.append(block)
                    break
                }
            }
        }

        // ③ 正文语义 id/class（维基百科实测命中 mw-content-text / id="content"）
        for marker in ["mw-content-text", "id=\"content\"", "class=\"content\"",
                       "id='content'", "class='content'", "id=\"main\"", "class=\"main\"",
                       "class=\"article\"", "class=\"post\"", "class=\"entry-content\""] {
            guard let r = html.range(of: marker, options: .caseInsensitive),
                  let tagStart = html[..<r.lowerBound].lastIndex(of: "<") else { continue }
            for name in ["div", "main", "section", "article"] {
                if let block = balancedElement(in: html, from: tagStart, name: name) {
                    if block.count > 400 { candidates.append(block) }
                    break
                }
            }
        }

        // 取最长候选（正文一定比同名小容器大）；都不够大就放弃裁剪
        guard let best = candidates.max(by: { $0.count < $1.count }), best.count > 400 else { return nil }
        return best
    }

    /// 从 `start`（指向 `<` ）开始，按**同名标签的嵌套配平**取出 `<name>…</name>` 整块。
    ///
    /// 为什么必须配平：直接找第一个 `</div>` 会**提前截断** ——
    /// 实测维基百科正文容器里嵌了十几层 div，第一个 `</div>` 出现在正文之前。
    ///
    /// ⚠️ 实现上有个**必须避开的坑**（本仓实测踩到，导致函数静默返回 nil）：
    /// 不能把「在 `html` 上算出来的 `String.Index`」传进只截取了片段的新 `String`
    /// （例如 `let tag = String(rest[...])`）里再索引 —— 不同字符串的 Index 不通用，
    /// 这种越界在 release 下**不一定崩**，而是安静地算出错误结果或者提前退出，
    /// 表现为「明明有 `<main>` 和 `</main>`，配平却失败」。
    /// 所以这里一律**只比较字符串内容**，不跨字符串传 Index。
    nonisolated static func balancedElement(in html: String, from start: String.Index, name: String) -> String? {
        guard start < html.endIndex, html[start] == "<" else { return nil }
        guard let openEnd = html.range(of: ">", range: start..<html.endIndex)?.upperBound else { return nil }
        let openTag = String(html[start..<openEnd])
        if openTag.hasSuffix("/>") { return openTag }   // 自闭合没有内容

        // 用 tagMatchesName(String) 判定，避免跨字符串 Index
        var depth = 1
        var cursor = openEnd
        var guardCount = 0
        while cursor < html.endIndex, guardCount < 20000 {
            guardCount += 1
            guard let lt = html[cursor...].firstIndex(of: "<") else { break }
            let rest = html[lt...]

            // 跳过注释整块（注释里的 <div> 不参与计数）
            if rest.hasPrefix("<!--") {
                if let end = rest.range(of: "-->")?.upperBound {
                    cursor = end
                    continue
                }
                break
            }
            guard let gt = rest.firstIndex(of: ">") else { break }
            let tag = String(rest[rest.startIndex...gt])   // 独立字符串，只用内容比较

            if tag.hasPrefix("</") {
                if tagMatchesName(tag, name: name) {
                    depth -= 1
                    if depth == 0 { return String(html[start...gt]) }
                }
            } else {
                if tagMatchesName(tag, name: name), !tag.hasSuffix("/>") {
                    depth += 1
                }
            }
            cursor = html.index(after: gt)
        }
        return nil   // 没配平成功 → 放弃（调用方保留全文）
    }

    /// 判断标签串（如 `<div class=...>` / `</div >`）是否正好是标签名 `name`：
    /// 去掉开头的 `<` 或 `</` 后，名字部分必须完全相等，且后面紧跟空白 / `>` / `/`
    /// （否则 `div` 会命中 `divx`，`head` 会命中 `header` —— 这正是本项目踩过的坑）。
    nonisolated static func tagMatchesName(_ tag: String, name: String) -> Bool {
        var body = Substring(tag)
        guard body.hasPrefix("<") else { return false }
        body = body.dropFirst()
        if body.hasPrefix("/") { body = body.dropFirst() }
        guard body.count >= name.count else { return false }
        let head = body.prefix(name.count)
        guard head.lowercased() == name.lowercased() else { return false }
        let after = body.index(body.startIndex, offsetBy: name.count)
        guard after < body.endIndex else { return false }
        let c = body[after]
        return c.isWhitespace || c == ">" || c == "/"
    }

    /// 删除 `open ... close` 之间的整块（不区分大小写；找不到 close 就删到结尾）
    nonisolated static func removeBlocks(in s: String, open: String, close: String) -> String {
        var result = s
        // 上限保护：防止畸形 HTML 造成死循环
        var guardCount = 0
        while guardCount < 200,
              let start = result.range(of: open, options: .caseInsensitive)?.lowerBound {
            guardCount += 1
            if let end = result.range(of: close, options: .caseInsensitive, range: start..<result.endIndex)?.upperBound {
                result.removeSubrange(start..<end)
            } else {
                result.removeSubrange(start..<result.endIndex)
            }
        }
        return result
    }

    /// 删除整个 `<name ...> ... </name>` 元素，**按标签边界匹配**。
    ///
    /// 与 `removeBlocks` 的区别（实测血泪）：
    /// `removeBlocks(open: "<head")` 会把 `<header>` 也当开标签 —— `<head` 正是 `<header`
    /// 的前缀。维基百科页面实测 `<head` 出现 3 次而 `</head>` 只有 1 次，
    /// 于是删除范围失控、106KB 正文被吃掉（`fetch` 只返回 5 个字符「跳转到内容」）。
    /// 这里要求标签名后紧跟空白 / `>` / `/`（确认真是该标签），
    /// 闭合标签同样校验右边界，并处理 `</script >` 这类带空白的写法。
    /// 找不到闭合标签时**不删**（宁可不删，也不能误删半个文档）。
    nonisolated static func removeElement(in s: String, name: String) -> String {
        var result = s
        var searchStart = result.startIndex
        var guardCount = 0

        while guardCount < 500, searchStart < result.endIndex {
            guardCount += 1
            guard let openRange = result.range(of: "<\(name)", options: .caseInsensitive,
                                               range: searchStart..<result.endIndex) else { break }
            // 标签边界校验：名字后必须是空白 / '>' / '/'，否则是别的标签（head vs header）
            let afterName = openRange.upperBound
            let boundaryOK = afterName < result.endIndex
                && (result[afterName].isWhitespace || result[afterName] == ">" || result[afterName] == "/")
            guard boundaryOK else {
                searchStart = openRange.upperBound
                continue
            }
            // 找对应的闭合标签
            let closeNeedle = "</\(name)"
            guard let closeRange = result.range(of: closeNeedle, options: .caseInsensitive,
                                                range: afterName..<result.endIndex) else {
                searchStart = afterName
                continue
            }
            let afterClose = closeRange.upperBound
            guard afterClose < result.endIndex,
                  result[afterClose].isWhitespace || result[afterClose] == ">" else {
                searchStart = closeRange.upperBound
                continue
            }
            let endOfElement = result.range(of: ">", range: afterClose..<result.endIndex)?.upperBound ?? afterClose
            result.removeSubrange(openRange.lowerBound..<endOfElement)
            searchStart = result.startIndex
        }
        return result
    }

    /// 响应体解码：UTF-8 → GB18030（中文站常见）→ Latin-1（兜底不丢字节）
    public nonisolated static func decodeBody(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        let gbRaw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gbRaw)) { return s }
        return String(data: data, encoding: .isoLatin1)
    }
}

// ============================================================================
// MARK: - 小工具
// ============================================================================

extension String {
    /// 压缩空白：行内连续空白 → 单空格；≥2 换行 → 2 换行；每行首尾去空白。
    func collapsedWhitespace() -> String {
        var out = ""
        out.reserveCapacity(count)
        var lastWasNewline = false
        var pendingSpace = false
        var newlineRun = 0
        for ch in self {
            if ch == "\n" || ch == "\r" {
                newlineRun += 1
                if newlineRun <= 2 {
                    out.append("\n")
                }
                lastWasNewline = true
                pendingSpace = false
                continue
            }
            newlineRun = 0
            if ch == " " || ch == "\t" || ch == "\u{00A0}" || ch == "\u{3000}" {
                if !lastWasNewline { pendingSpace = true }
                continue
            }
            if pendingSpace, !out.isEmpty, !out.hasSuffix("\n") {
                out.append(" ")
            }
            pendingSpace = false
            out.append(ch)
            lastWasNewline = false
        }
        return out
    }
}

// ============================================================================
// MARK: - 自检（--websearch-selftest）
// ============================================================================
//
//  跑法：`swift run AuroraDrive --websearch-selftest ["查询词"] [--network]`
//
//  · 默认（离线）：解析器 / 跳转解包 / 正文提取 / 反爬识别 / Wikipedia JSON，
//    全部用**本机实测抓下来的原始 HTML 夹具** —— 断言的是真实格式，不是我脑补的格式。
//  · --network：真的发一次 search + 一次 fetch，把**真实条数**打印出来。
//    失败会以非 0 退出码返回（渠道挂了必须能看出来）。
//
//  返回：失败项数（0 = 全过），与仓库其它自检同一约定。

public enum WebSearchSelfTest {

    // 夹具 1：DDG Lite 原始 HTML（2026-10-06 本机 `POST /lite/` 抓取，逐字节照抄，只截了前 2 条）
    static let ddgLiteFixture = """
    <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
    <html><head><title>swift actor at DuckDuckGo</title></head>
    <body>
    <form action="/lite/" method="post">
      <input class='query' type="text" size="40" name="q" value="swift actor">
    </form>
    <table>
      <tr><td valign="top">1.&nbsp;</td>
      <td><a rel="nofollow" href="https://developer.apple.com/documentation/swift/actor" class='result-link'>Actor | Apple Developer Documentation</a></td></tr>
      <tr><td>&nbsp;&nbsp;&nbsp;</td>
      <td class='result-snippet'>Overview The <b>Actor</b> protocol generalizes over all <b>actor</b> types. <b>Actor</b> types implicitly conform to this protocol.</td></tr>
      <tr><td valign="top">2.&nbsp;</td>
      <td><a rel="nofollow" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.hackingwithswift.com%2Fquick-start%2Fconcurrency%2Fwhat-is-an-actor&amp;rut=abc" class='result-link'>What is an actor and why does Swift have them?</a></td></tr>
      <tr><td>&nbsp;&nbsp;&nbsp;</td>
      <td class='result-snippet'><b>Swift</b> calls this <b>actor</b> isolation. Reading an <b>actor&#x27;s</b> property marks a suspension point.</td></tr>
    </table>
    </body></html>
    """

    // 夹具 2：DDG 403 反爬页（2026-10-06 实测原文，236 B）
    static let ddgBlockPageFixture = """
    If this persists, please <a href="mailto:error-lite+4a8a@duckduckgo.com?subject=Error getting results">email us</a>.<br />
    Our support email address includes an anonymized error code that helps us understand the context of your search.
    """

    // 夹具 3：Wikipedia list=search JSON（2026-10-06 实测原文，节选）
    static let wikipediaFixture = """
    {"batchcomplete":"","query":{"searchinfo":{"totalhits":11847},"search":[
      {"ns":0,"title":"异环","pageid":8809750,"size":13288,
       "snippet":"《<span class=\\"searchmatch\\">异</span><span class=\\"searchmatch\\">环</span>》（英语：Neverness to Everness）是一款开放世界动作角色扮演游戏。"}]}}
    """

    // 夹具 4：正文提取样本
    static let articleFixture = """
    <html><head><title>标题</title><style>body{color:red}</style>
    <script>var x = 1 < 2 && 3 > 2;</script></head>
    <body><h1>第一章</h1><p>第一段 &amp; 实体 &#x27;引号&#x27;。</p>
    <noscript>请开启 JS</noscript><div>第二段   多个空格</div></body></html>
    """

    // 夹具 5：**回归夹具** —— `<header>` 不能被当成 `<head>` 删掉。
    // 结构照抄 2026-10-06 实测的维基百科页面（实测该页 `<head` 出现 3 次 / `</head>` 仅 1 次，
    // 当时 `removeBlocks("<head","</head>")` 把正文整块吃掉，fetch 只剩 5 个字符）。
    static let headerVsHeadFixture = """
    <html><head><title>T</title></head><body>
    <header class="vector-header mw-header no-font-mode-scale"><div>导航栏</div></header>
    <div id="content"><p>这是正文第一段，必须被保留下来。</p>
    <header>小节标题</header><p>这是正文第二段，也必须保留。</p></div>
    </body></html>
    """

    /// 运行自检。返回失败项数。
    public static func run(query: String, network: Bool) async -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("  \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        print("═══ W5 联网搜索自检（WebSearch.swift）═══")
        print("模式：\(network ? "离线 + 真实网络" : "离线（加 --network 跑真实请求）")")

        // ── 1. DDG Lite 解析（真实格式夹具）──
        print("\n[1] DuckDuckGo Lite 解析（实测 HTML 夹具）")
        let lite = WebSearch.parseDuckDuckGoLite(html: ddgLiteFixture, maxResults: 10)
        check("解析出 2 条结果", lite.count == 2, "实际 \(lite.count) 条")
        if let first = lite.first {
            check("直链原样保留", first.url == "https://developer.apple.com/documentation/swift/actor", first.url)
            check("标题去标签", first.title == "Actor | Apple Developer Documentation", first.title)
            check("摘要非空且无标签", !first.snippet.isEmpty && !first.snippet.contains("<"), first.snippet.prefix(50) + "…")
        } else {
            check("首条存在", false)
        }
        if lite.count > 1 {
            check("uddg 跳转已解包", lite[1].url == "https://www.hackingwithswift.com/quick-start/concurrency/what-is-an-actor",
                  lite[1].url)
            check("实体 &#x27; 已解码", lite[1].snippet.contains("actor's"), lite[1].snippet.prefix(40) + "…")
        }

        // ── 2. 跳转解包（单独函数）──
        print("\n[2] DDG 跳转包装解包")
        let wrapped = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1%26c%3D2&rut=xyz"
        check("uddg percent-decode（含 & 参数）",
              WebSearch.decodeDuckDuckGoRedirect(href: wrapped) == "https://example.com/a?b=1&c=2",
              WebSearch.decodeDuckDuckGoRedirect(href: wrapped) ?? "nil")
        check("协议相对链接补 https",
              WebSearch.decodeDuckDuckGoRedirect(href: "//example.org/x") == "https://example.org/x")
        check("非 http(s) 拒绝", WebSearch.decodeDuckDuckGoRedirect(href: "javascript:alert(1)") == nil)
        check("中文查询 percent 编码",
              WebSearch.percentEncodeQuery("异环 攻略") == "%E5%BC%82%E7%8E%AF%20%E6%94%BB%E7%95%A5",
              WebSearch.percentEncodeQuery("异环 攻略"))

        // ── 3. 反爬页识别（真实 403 原文）──
        print("\n[3] 反爬/验证码页识别")
        check("DDG error-lite 403 页被识别", WebSearch.looksLikeBlockPage(ddgBlockPageFixture))
        check("正常结果页不误判", !WebSearch.looksLikeBlockPage(ddgLiteFixture))
        check("Mojeek Captcha 页被识别", WebSearch.looksLikeBlockPage("<title>Captcha</title>"))
        check("拦截原因含指纹说明", WebSearch.blockReason(from: ddgBlockPageFixture, code: 403).contains("error-lite"),
              WebSearch.blockReason(from: ddgBlockPageFixture, code: 403))

        // ── 4. 正文提取 ──
        print("\n[4] HTML → 纯文本")
        let body = WebSearch.plainText(fromHTML: articleFixture, maxCharacters: 8000)
        check("script/style 已删除", !body.contains("var x") && !body.contains("color:red"))
        check("noscript 已删除", !body.contains("请开启 JS"))
        check("标签已删除", !body.contains("<"))
        check("实体已解码", body.contains("& 实体 '引号'"), body.replacingOccurrences(of: "\n", with: "⏎"))
        check("多余空格已压缩", !body.contains("    "))
        let truncated = WebSearch.plainText(fromHTML: articleFixture, maxCharacters: 10)
        check("截断生效", truncated.contains("已截断"), truncated.replacingOccurrences(of: "\n", with: "⏎"))
        check("空 HTML → 空串", WebSearch.plainText(fromHTML: "<html><body></body></html>", maxCharacters: 100).isEmpty)

        // ── 4b. 回归看门：`<header>` 不能被当成 `<head>` 删掉 ──
        //     （2026-10-06 实测 bug：维基百科页 `<head` 3 次 / `</head>` 1 次 → 正文被吃光）
        print("\n[4b] 回归：<head> vs <header> 边界（实测 bug 的看门测试）")
        let headerBody = WebSearch.plainText(fromHTML: headerVsHeadFixture, maxCharacters: 8000)
        check("正文第一段未丢失", headerBody.contains("这是正文第一段"),
              headerBody.replacingOccurrences(of: "\n", with: "⏎"))
        check("正文第二段未丢失", headerBody.contains("这是正文第二段"))
        check("嵌套 <header> 不吞后文", headerBody.contains("也必须保留"))
        check("removeElement: <header> 不受 head 影响",
              WebSearch.removeElement(in: "<header>X</header>", name: "head") == "<header>X</header>",
              WebSearch.removeElement(in: "<header>X</header>", name: "head"))
        check("removeElement: 正常删除 <head>",
              WebSearch.removeElement(in: "<head>X</head><body>Y</body>", name: "head") == "<body>Y</body>",
              WebSearch.removeElement(in: "<head>X</head><body>Y</body>", name: "head"))
        let unclosed = WebSearch.removeElement(in: "<script>var a=1;<body>内容</body>", name: "script")
        check("无闭合标签时不误删到结尾", unclosed.contains("内容"), unclosed)
        // 这条专门盯住**开标签边界检查**（变异测试证明它是"活的"：
        // 去掉边界检查后，下面这串输入里 `<header>` 会被当成 `<head` 整个吃掉）。
        let boundaryCase = "<header></head><head>REAL</head><body>BODY</body>"
        let boundaryOut = WebSearch.removeElement(in: boundaryCase, name: "head")
        check("开标签边界检查不可省（<header> 必须存活）",
              boundaryOut.hasPrefix("<header>") && !boundaryOut.contains("REAL"),
              boundaryOut)

        // ── 4c. 回归看门：balancedElement（嵌套配平）──
        //     （2026-10-06 实测 bug：把在 html 上算出的 String.Index 传进新 String 里索引，
        //      配平静默失败 → extractMainContent 永远返回 nil → 正文被导航噪声淹没）
        print("\n[4c] 回归：嵌套配平取正文块")
        let nestedFixture = """
        <html><body><div id="content"><p>正文A</p><div><p>正文B</p><div>正文C</div></div>
        <p>正文D</p></div><div>页脚噪声</div></body></html>
        """
        if let block = WebSearch.balancedElement(
            in: nestedFixture,
            from: nestedFixture.range(of: "<div id=\"content\"")!.lowerBound,
            name: "div") {
            let text = WebSearch.stripTags(block).collapsedWhitespace()
            check("嵌套 div 取整块（不提前截断）", text.contains("正文A") && text.contains("正文B") && text.contains("正文D"),
                  text.replacingOccurrences(of: "\n", with: "⏎"))
            check("不吞容器外的兄弟节点", !text.contains("页脚噪声"), text)
        } else {
            check("嵌套 div 配平成功", false, "balancedElement 返回 nil（Index 跨字符串 bug 复现）")
        }
        check("标签名边界：div 不命中 divx",
              !WebSearch.tagMatchesName("<divx>", name: "div") && WebSearch.tagMatchesName("<div>", name: "div"))
        check("标签名边界：head 不命中 header",
              !WebSearch.tagMatchesName("<header>", name: "head")
              && WebSearch.tagMatchesName("</head>", name: "head"))
        check("自闭合标签不参与配平",
              WebSearch.tagMatchesName("<br/>", name: "br") && WebSearch.tagMatchesName("</br>", name: "br"))

        // ── 5. Wikipedia JSON ──
        print("\n[5] Wikipedia 兜底解析（实测 JSON 夹具）")
        let wiki = WebSearch.parseWikipediaSearchJSON(text: wikipediaFixture)
        check("解析出 1 条", wiki.count == 1, "实际 \(wiki.count) 条")
        if let w = wiki.first {
            check("标题正确", w.title == "异环", w.title)
            check("URL 指向维基", w.url.contains("wikipedia.org/wiki/"), w.url)
            check("摘要已去 searchmatch 标签", !w.snippet.contains("<span"), w.snippet.prefix(40) + "…")
            check("来源如实标注 wikipedia", w.source == "wikipedia", w.source)
        } else {
            check("Wikipedia 首条存在", false)
        }
        check("坏 JSON 不崩、返回空", WebSearch.parseWikipediaSearchJSON(text: "{oops").isEmpty)
        check("opensearch 形态兼容",
              WebSearch.parseWikipediaSearchJSON(text: "[\"q\",[\"A\"],[\"desc\"],[\"https://zh.wikipedia.org/wiki/A\"]]").count == 1)

        // ── 6. 错误如实（不编数据）──
        print("\n[6] 失败如实抛错（红线：绝不返回假结果）")
        do {
            _ = try await WebSearch.shared.search(query: "   ", maxResults: 5)
            check("空查询应抛错", false, "居然返回了结果")
        } catch let e as WebSearchError {
            check("空查询抛 invalidQuery", { if case .invalidQuery = e { return true }; return false }(), e.errorDescription ?? "")
        } catch {
            check("空查询抛 WebSearchError", false, "\(error)")
        }
        do {
            _ = try await WebSearch.shared.fetch(url: "file:///etc/passwd")
            check("非 http URL 应抛错", false, "居然抓了本地文件")
        } catch let e as WebSearchError {
            check("非 http URL 抛 invalidURL", { if case .invalidURL = e { return true }; return false }(), e.errorDescription ?? "")
        } catch {
            check("非 http URL 抛 WebSearchError", false, "\(error)")
        }

        // ── 7. 真实网络（可选）──
        if network {
            print("\n[7] 真实网络请求（--network）")
            let q = query.isEmpty ? "异环 游戏" : query
            let started = Date()
            do {
                let hits = try await WebSearch.shared.search(query: q, maxResults: 5)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                check("真实搜索返回非空", !hits.isEmpty, "「\(q)」→ \(hits.count) 条，\(ms)ms")
                for (i, h) in hits.prefix(5).enumerated() {
                    print("     [\(i + 1)] (\(h.source)) \(h.title.prefix(60))")
                    print("         \(h.url.prefix(110))")
                    print("         \(h.snippet.prefix(100))")
                }
                check("结果 URL 都是 http(s)", hits.allSatisfy { $0.url.hasPrefix("http") })
                check("结果都有非空标题", hits.allSatisfy { !$0.title.isEmpty })
            } catch let e as WebSearchError {
                check("真实搜索成功", false, "[\(e.kindLabel)] \(e.errorDescription ?? "")")
            } catch {
                check("真实搜索成功", false, "\(error)")
            }

            let fetchTarget = "https://zh.wikipedia.org/wiki/%E5%BC%82%E7%8E%AF"
            do {
                let text = try await WebSearch.shared.fetch(url: fetchTarget, maxCharacters: 600)
                check("真实 fetch 返回正文", text.count > 100, "\(text.count) 字符")
                print("     fetch 摘录：\(text.prefix(160).replacingOccurrences(of: "\n", with: "⏎"))")
            } catch let e as WebSearchError {
                check("真实 fetch 成功", false, "[\(e.kindLabel)] \(e.errorDescription ?? "")")
            } catch {
                check("真实 fetch 成功", false, "\(error)")
            }
        }

        print("\n═══ 结果：\(failures == 0 ? "全部通过" : "\(failures) 项失败") ═══")
        return failures
    }

    /// 解析 `--websearch-selftest` 之后的位置参数（查询词），并执行。
    /// 供 AuroraDriveApp 的 CLI 分支调用（W8 负责把入口登记进 oneShotFlags）。
    public static func runFromCommandLine(_ args: [String]) async -> Int32 {
        var query = ""
        var network = false
        if let i = args.firstIndex(of: "--websearch-selftest") {
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                query = args[i + 1]
            }
        }
        if args.contains("--network") { network = true }
        let failed = await run(query: query, network: network)
        return Int32(min(failed, 127))
    }
}
