// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  QuestPanelReader.swift — 任务面板 OCR → 世界坐标（UE5 厘米）
// ============================================================================
//
//  【这条链路解决什么】
//    游戏左侧任务面板上写着「与路边着急的研究员对话」，玩家看得懂，车看不懂。
//    Python 侧已经把 39 张任务表（tools/nte_datatables）编译成
//    `models/quest_index.json`（1372 个精确文本 → 2938 条带坐标的目标）。
//    本文件把那张索引接到运行时：**OCR 读面板 → 匹配 → setLocatorTarget**。
//
//  【数据流】
//    CaptureEngine 帧（tick 主线程取到 currentFrameCG）
//      → 裁 questROI（归一化，左上原点）
//      → Vision VNRecognizeTextRequest（zh-Hans）
//      → 过滤提示行 → 多行拼成查询文本
//      → 投票缓冲（连续 3 次相同才确认）
//      → 四路匹配 exact → substr → core → fuzzy（+ byname 兜底）
//      → verdict 判定（ok / ambiguous / low / miss）
//      → ambiguous 时走 NextQuests 链消歧
//      → state.setLocatorTarget(x:y:) + state.questName
//
//  ══════════════════════════════════════════════════════════════════════════
//  【红线 1：坐标系 —— 一个转换都不做】
//  ══════════════════════════════════════════════════════════════════════════
//    `quest_index.json` 里的 x/y/z 是**世界坐标（UE5 厘米）**，
//    `DriveState.locatorTarget` 存的**也是**世界坐标（UE5 厘米，
//    见 AuroraDriveApp.swift:4396 与 MissionConsole.swift:3662 的既有注释）。
//    两边同系 ⟹ **直接传，不做任何换算**。
//
//    ⚠️ 特别提醒后来者：项目里还有另一套「地图像素」坐标（`worldToMapPixel`，
//       正确地图尺寸 13056）。那是**地图渲染**用的，与本文件无关。
//       历史事故正是「两套坐标在同一流程里来回倒手」，此处刻意不碰。
//
//  ══════════════════════════════════════════════════════════════════════════
//  【红线 2：不碰游戏进程】
//  ══════════════════════════════════════════════════════════════════════════
//    全程只读**屏幕像素**（CaptureEngine 已有的截屏流）。不读游戏内存、
//    不注入、不 hook。与 SpeedOCRReader 同一性质。
//
//  ══════════════════════════════════════════════════════════════════════════
//  【与 Python 参考实现（tools/quest/quest_matcher.py）的关系】
//  ══════════════════════════════════════════════════════════════════════════
//    本文件是 `quest_matcher.py` 的 Swift 移植。**逐位对齐**是硬要求，
//    所以下面每个原语都注明对应 Python 的哪一段，并且 `--quest-selftest`
//    会把这些原语拿去和 Python 生成的向量对拍。
//
//    ⚠️ 移植时踩到的两个坑，记在这里免得后人再踩：
//
//    坑 1：`difflib.SequenceMatcher.ratio()` **不是**「最长公共子序列 × 2 / 总长」。
//          它是 Ratcliff-Obershelp：递归地在左右剩余区间继续找最长匹配块并**累加**。
//          第一版只算了单个最长块 → 与 Python 最大偏差 0.476（348 对里错 226 对）。
//          正确实现见 `sequenceRatio`。
//
//    坑 2：Python 的 `len()` 按 **Unicode 码点**计数，Swift 的 `Character` 按
//          **字素簇**计数。索引里有 4 条 key 含 CRLF（"前往赤龙古堡\r\n（小队成员…）"）
//          —— Python 算 2 个字符，Swift 算 1 个 → 长度比、切片、长度守卫全部错位。
//          故本文件**全程用 `Unicode.Scalar`**，不用 `Character`。
//          （修掉后：5157 对向量零偏差。）
//
//    坑 3：Python 里 `core_candidates` 返回的是 `sorted(set(...))`，
//          **同长度候选之间的顺序随 PYTHONHASHSEED 漂移**（实测 seed=0 与 seed=2
//          给出相反顺序）。这不是可移植语义。本文件改成**确定性的插入序**
//          （`s` 本体 → 正则分组 1 → 分组 2 …），跨进程稳定。
//
//  ══════════════════════════════════════════════════════════════════════════
//  【自检】
//  ══════════════════════════════════════════════════════════════════════════
//      ./AuroraDrive --quest-selftest
//    用 tools/quest 里那 8 条真实面板文字做回归，另加反向用例（假阳性）、
//    投票、链消歧、坐标语义、ROI 提示行过滤。退出码 = 失败项数。
// ============================================================================

import CoreGraphics
import Foundation
import ImageIO
import QuartzCore   // CACurrentMediaTime（单调时钟，节流用）
import Vision

// MARK: - 索引数据模型

/// 一条「任务目标 → 世界坐标」记录。
///
/// 对应 `quest_index.json` 里 `exact/core/byname` 三个字典的 value 元素。
/// `x/y/z` 是**世界坐标（UE5 厘米）**；缺坐标的条目在索引生成阶段就被滤掉了，
/// 但 x 与 y 仍可能各自缺失（生成器只要求 `x or y or z` 至少一个为真），
/// 故这里保留可选性，取目标点时要求 x、y 同时存在。
struct QuestEntry: Sendable, Equatable {
    let qid: String
    let quest: String
    let desc: String
    let x: Double?
    let y: Double?
    let z: Double?

    /// 世界坐标目标点（UE5 厘米）。x 或 y 缺失 → nil（该条不可用于寻路）。
    var worldTarget: (x: Double, y: Double)? {
        guard let x, let y else { return nil }
        return (x, y)
    }
}

/// 命中的是哪一路匹配（对应 Python 的 `how` 字段前缀）。
enum QuestMatchKind: String, Sendable {
    case exact          // 完整文本命中
    case substr         // 子串命中（带长度比 ≥0.5 守卫）
    case core           // 剥前缀后的核心词直接命中
    case coreSub = "core-sub"   // 核心词子串命中
    case fuzzy          // 模糊命中（SequenceMatcher 等价，阈值 0.62）
    case name           // 任务名兜底
}

/// 置信判定 —— **只有 `.ok` 允许用于寻路**。
///
/// 对应 Python 的 `match_confident()`。门槛的存在理由：裸匹配会把
/// 「对话」这种 2 字碎片判成唯一命中（实测 364 个候选），而真实面板文字
/// 以 4~7 字为主 —— 短查询本来就该判存疑，不是"匹配成功"。
enum QuestVerdict: String, Sendable {
    case ok             // 唯一且可信 → 可寻路
    case ambiguous      // 多候选 → 需链消歧，消歧不掉就等下一帧
    case low            // 文本太短 / 模糊分太低 → 丢弃
    case miss           // 没匹配上
}

/// 一次匹配的完整结果。
struct QuestMatch: Sendable {
    let entries: [QuestEntry]
    let kind: QuestMatchKind?
    let score: Double
    let verdict: QuestVerdict
    /// 清洗后的查询文本（已剥标签、去首尾空白）
    let query: String
    /// 匹配细节（命中的 core key / fuzzy 得分等），只用于日志与自检
    let hint: String
}

/// 一次「确认」的输出，交给 DriveState 落库。
struct QuestPanelReading: Sendable {
    let text: String
    let questName: String
    let target: (x: Double, y: Double)?
    let qid: String
    let kind: QuestMatchKind
    let resolvedBy: String
}

// MARK: - 任务链索引（NextQuests / PreQuests）

/// `qid → NextQuests / ChapterProgress` 图，用于多候选消歧。
///
/// 数据源是 `tools/nte_datatables/**/DT_Quest*.json`（32 个文件 / 20 MB）。
/// ⚠️ 只在**真的遇到多候选**时才懒加载 —— 唯一命中的常见路径一次磁盘都不碰。
struct QuestChainIndex: Sendable {
    let next: [String: [String]]
    let progress: [String: Double]

    static func load(root: URL) -> QuestChainIndex {
        var next: [String: [String]] = [:]
        var progress: [String: Double] = [:]
        let fm = FileManager.default
        let base = root.appendingPathComponent("tools/nte_datatables")
        guard let en = fm.enumerator(at: base, includingPropertiesForKeys: nil) else {
            return QuestChainIndex(next: [:], progress: [:])
        }
        for case let url as URL in en {
            let name = url.lastPathComponent
            guard name.hasPrefix("DT_Quest"), name.hasSuffix(".json") else { continue }
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
            // 结构可能是 {Rows:{...}}，也可能是 [{Rows:{...}}]
            var doc: [String: Any]?
            if let d = obj as? [String: Any] { doc = d }
            else if let arr = obj as? [Any], let f = arr.first as? [String: Any] { doc = f }
            guard let rows = doc?["Rows"] as? [String: Any] else { continue }

            for (qid, v) in rows {
                guard let row = v as? [String: Any] else { continue }
                if let nx = row["NextQuests"] as? [Any] {
                    let list = nx.compactMap { $0 as? String }.filter { !$0.isEmpty && $0 != "None" }
                    if !list.isEmpty { next[qid] = list }
                }
                if let p = num(row["ChapterProgress"]) { progress[qid] = p }
            }
        }
        return QuestChainIndex(next: next, progress: progress)
    }

    private static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }
}

// MARK: - 任务索引

/// `models/quest_index.json` 的内存形式。
struct QuestIndex: Sendable {
    let exact: [String: [QuestEntry]]
    let core: [String: [QuestEntry]]
    let byname: [String: [QuestEntry]]
    /// 字典迭代顺序在 Swift 里**每个进程都不同**（哈希随机化）。
    /// 凡是算法需要"遍历所有 key"的分支都走这份排序后的数组，
    /// 保证同一个输入在任何进程、任何运行次数下都给出同一个结果。
    let exactKeys: [String]
    let coreKeys: [String]
    let bynameKeys: [String]
    let stats: [String: Int]

    static func load(url: URL) -> QuestIndex? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let doc = obj as? [String: Any] else { return nil }

        func parse(_ key: String) -> [String: [QuestEntry]] {
            guard let m = doc[key] as? [String: Any] else { return [:] }
            var out: [String: [QuestEntry]] = [:]
            out.reserveCapacity(m.count)
            for (k, v) in m {
                guard let arr = v as? [Any] else { continue }
                var list: [QuestEntry] = []
                list.reserveCapacity(arr.count)
                for e in arr {
                    guard let d = e as? [String: Any] else { continue }
                    list.append(QuestEntry(
                        qid: (d["qid"] as? String) ?? "",
                        quest: (d["quest"] as? String) ?? "",
                        desc: (d["desc"] as? String) ?? "",
                        x: num(d["x"]), y: num(d["y"]), z: num(d["z"])))
                }
                if !list.isEmpty { out[k] = list }
            }
            return out
        }

        let exact = parse("exact"), core = parse("core"), byname = parse("byname")
        var st: [String: Int] = [:]
        if let s = doc["stats"] as? [String: Any] {
            for (k, v) in s { if let n = v as? NSNumber { st[k] = n.intValue } }
        }
        return QuestIndex(exact: exact, core: core, byname: byname,
                          exactKeys: exact.keys.sorted(),
                          coreKeys: core.keys.sorted(),
                          bynameKeys: byname.keys.sorted(),
                          stats: st)
    }

    private static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }
}

// MARK: - 文本原语（与 Python 逐位对齐）

enum QuestText {

    /// Python `TAGS.sub("", s).strip()` —— 去掉 `<blue>…</>` 这类富文本标签。
    ///
    /// ⚠️ 返回 `[Unicode.Scalar]` 而不是 `String`：见文件头「坑 2」。
    static func clean(_ s: String) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var depth = 0
        for sc in s.unicodeScalars {
            if sc == "<" { depth += 1; continue }
            if sc == ">" { if depth > 0 { depth -= 1 }; continue }
            if depth == 0 { out.append(sc) }
        }
        // Python str.strip() 的空白集合（比 Swift .whitespaces 更贴近 CPython）
        let ws = Set<Unicode.Scalar>(" \t\n\r\u{0B}\u{0C}".unicodeScalars)
        var lo = 0, hi = out.count
        while lo < hi, ws.contains(out[lo]) { lo += 1 }
        while hi > lo, ws.contains(out[hi - 1]) { hi -= 1 }
        return Array(out[lo..<hi])
    }

    static func string(_ s: [Unicode.Scalar]) -> String {
        String(String.UnicodeScalarView(s))
    }

    /// Python `PREFIX_PATTERNS`，**逐字照抄**（顺序即优先级）。
    static let prefixPatterns: [String] = [
        "^与(.+?)(对话|交谈|交流|会合|碰面|见面)$",
        "^和(.+?)(对话|交谈|交流|会合)$",
        "^向(.+?)(对话|询问|打听)$",
        "^跟随(.+?)(前往|来到|抵达)?(.+)?$",
        "^前往(.+)$", "^抵达(.+)$", "^进入(.+)$", "^走进(.+)$",
        "^离开(.+)$", "^找到(.+)$", "^寻找(.+)$", "^调查(.+)$",
        "^击败(.+)$", "^收集(.+)$", "^取得(.+)$", "^使用(.+)$",
        "^搭乘(.+)$", "^等待(.+)$", "^聆听(.+)$", "^查看(.+)$",
        "^完成(.+)$",
        "^\\[(.+?)\\](.+)$", "^【(.+?)】(.+)$",
    ]

    private static let compiled: [NSRegularExpression] =
        prefixPatterns.compactMap { try? NSRegularExpression(pattern: $0) }

    private static let trailingPunct =
        try! NSRegularExpression(pattern: "[，。！？、,.!?…·—\\-]+$")

    /// Python `core_candidates(desc)`。
    ///
    /// 剥掉装饰性前缀，给出候选核心词，**按长度降序**。
    ///
    /// ⚠️ 与 Python 的有意差异：Python 用 `sorted(set(...))`，同长度候选的
    ///    相对顺序随 PYTHONHASHSEED 漂移（实测 seed=0/2 结果相反）。这里改成
    ///    确定性插入序：`s` 本体 → 正则分组 1 → 分组 2 → …。
    ///    索引生成器（build_quest_index.py）用的也是同一个集合语义，
    ///    故 `core` 表内容不受影响，只有**候选顺序**变确定。
    static func coreCandidates(_ desc: String) -> [String] {
        let sc = clean(desc)
        if sc.isEmpty { return [] }
        let s = string(sc)

        var cands: [String] = [s]
        var seen = Set<String>([s])
        let ns = s as NSString
        for re in compiled {
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            for g in 1..<m.numberOfRanges {
                let r = m.range(at: g)
                if r.location == NSNotFound { continue }
                let grp = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
                if grp.unicodeScalars.count >= 2, !seen.contains(grp) { seen.insert(grp); cands.append(grp) }
            }
        }

        var out: [String] = []
        var seenOut = Set<String>()
        for c in cands {
            let cns = c as NSString
            var t = trailingPunct.stringByReplacingMatches(
                in: c, range: NSRange(location: 0, length: cns.length), withTemplate: "")
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.unicodeScalars.count >= 2, !seenOut.contains(t) { seenOut.insert(t); out.append(t) }
        }
        // 稳定按长度降序
        return out.enumerated().sorted { l, r in
            let a = l.element.unicodeScalars.count, b = r.element.unicodeScalars.count
            return a != b ? a > b : l.offset < r.offset
        }.map { $0.element }
    }

    /// `difflib.SequenceMatcher(None, a, b).ratio()` 的等价实现。
    ///
    /// Ratcliff-Obershelp 相似度：`2 × 全部匹配块大小之和 / (len(a) + len(b))`。
    /// 递归地在左右剩余区间继续找最长匹配块并**累加** —— 不是只取最长的那一块。
    static func sequenceRatio(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Double {
        let n = a.count, m = b.count
        if n == 0 && m == 0 { return 1.0 }
        if n == 0 || m == 0 { return 0.0 }

        // b2j：字符 → b 中全部下标（升序），对应 Python `_chain_b()`
        var b2j = [Unicode.Scalar: [Int]]()
        for (j, ch) in b.enumerated() { b2j[ch, default: []].append(j) }

        /// `find_longest_match(alo, ahi, blo, bhi)`：最早出现、最长的匹配块。
        /// 平局规则与 Python 一致（外层 i 升序 + 严格 `>` 比较 → i 更小者胜）。
        func longestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
            var besti = alo, bestj = blo, bestsize = 0
            var j2len = [Int: Int]()
            if alo < ahi {
                for i in alo..<ahi {
                    var newj2len = [Int: Int]()
                    if let js = b2j[a[i]] {
                        for j in js {
                            if j < blo { continue }
                            if j >= bhi { break }
                            let k = (j2len[j - 1] ?? 0) + 1
                            newj2len[j] = k
                            if k > bestsize {
                                besti = i - k + 1
                                bestj = j - k + 1
                                bestsize = k
                            }
                        }
                    }
                    j2len = newj2len
                }
            }
            return (besti, bestj, bestsize)
        }

        var total = 0
        var queue: [(Int, Int, Int, Int)] = [(0, n, 0, m)]
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let (i, j, k) = longestMatch(alo, ahi, blo, bhi)
            if k > 0 {
                total += k
                if alo < i && blo < j { queue.append((alo, i, blo, j)) }
                if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
            }
        }
        return 2.0 * Double(total) / Double(n + m)
    }
}

// MARK: - 任务面板读取器

/// 任务面板 OCR → 世界坐标。`@MainActor`：可变状态只在主线程动。
///
/// 调用方（DriveState.tick）只需每 tick 喂一次当前帧：
/// ```
/// if let r = questPanel.ingest(cgImage: cg) {
///     if questName != r.questName { questName = r.questName }
///     if let t = r.target { setLocatorTarget(x: t.x, y: t.y) }
/// }
/// ```
/// 节流（0.7s）与投票都在本类内部完成，调用方不需要自己计时。
@MainActor
final class QuestPanelReader {

    // MARK: 常量

    /// 任务面板 ROI（归一化，**左上角原点，y 向下** —— 与
    /// `CaptureEngine.speedROINorm` 同一约定）。
    ///
    /// 2940×1912 下即 x 88~1176 / y 458~592；任务名行实测在 y 488~516。
    nonisolated static let questROI = CGRect(x: 0.030, y: 0.240, width: 0.370, height: 0.070)

    /// 连续多少次相同文本才确认（抗 OCR 抖动）。对应 Python `feed(need=3)`。
    nonisolated static let voteNeed = 3

    /// 两次 OCR 的最小间隔（秒）。**不是每帧跑** —— Vision OCR 是毫秒级开销，
    /// 30Hz 下每帧跑等于白烧 CPU，而任务面板文字的变化远慢于 0.7 秒。
    nonisolated static let minInterval: TimeInterval = 0.7

    /// 模糊匹配阈值。对应 Python `fuzzy_threshold=0.62`。
    nonisolated static let fuzzyThreshold = 0.62

    /// 查询文本最短长度。短于此一律不判 `.ok`（防「对话」这类碎片假阳性）。
    nonisolated static let minQueryLen = 4

    /// 模糊命中要判 `.ok`，得分还得 ≥ 这个值（0.62 只是"入选"，0.75 才是"可信"）。
    nonisolated static let fuzzyConfident = 0.75

    /// 多候选时，若所有候选的世界坐标都落在这么小的范围内，视为**等价目标**，
    /// 直接采用（任取其一，导航上无差别）。
    ///
    /// 这是相对 Python 参考实现的**有意增强**：Python 只做 NextQuests 链消歧，
    /// 链上找不到就永远等下一帧 —— 而"下一帧"不会让歧义消失（同样的文字
    /// 永远给出同样的候选集）。实测 346 个多候选 key 里有 111 个候选彼此
    /// 相距 ≤5m，这些本来就该放行；剩下 235 个跨度为公里级，必须拦住。
    nonisolated static let equivalentRadiusMeters: Double = 25.0

    /// 提示行过滤：面板上「V 按下进行追踪」落在 ROI 内，必须剔除，
    /// 否则会污染查询文本（OCR 拼成「与薄荷对话 V 按下进行追踪」→ 匹配失败）。
    nonisolated static func isHintLine(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.contains("按下") && (t.contains("追踪") || t.contains("跟踪")) { return true }
        if t.contains("进行追踪") || t.contains("进行跟踪") { return true }
        // 纯符号/纯 ASCII 单字母（如孤立的 "V"）不是任务文字
        let hasHan = t.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        if !hasHan && t.unicodeScalars.count <= 2 { return true }
        return false
    }

    // MARK: 状态

    /// 索引（懒加载一次，进程内共享）
    private var index: QuestIndex?
    private var indexLoadFailed = false
    /// 任务链（更贵：20MB，只在遇到多候选时才加载）
    private var chain: QuestChainIndex?
    private var chainTried = false

    private var lastRun: TimeInterval = 0
    private var voteText: String?
    private var voteCount = 0

    /// Vision OCR 专用串行队列。
    ///
    /// 独立队列而不是复用 captureQueue：后者是 SCStream 的 sampleHandlerQueue
    /// （`queueDepth=3`），在上面做同步计算会推迟帧消费并引发雪崩 ——
    /// 项目里已有一次实测记录（见 AuroraDriveApp.swift 的 onYoloFrame 回退说明：
    /// capGap 从 11ms 涨到 2081ms）。OCR 有 33ms 量级，绝不能放那条队列。
    private let ocrQueue = DispatchQueue(label: "aurora.quest.ocr", qos: .utility)

    /// 是否有一次 OCR 在途（防堆积：任务面板文字变化远慢于 0.7s）
    private var ocrInFlight = false

    /// 确认到任务时的回调（由 DriveState 接线，回主线程调用）
    var onConfirmed: ((QuestPanelReading) -> Void)?

    /// 最近一次确认的结果（UI / 诊断可读）
    private(set) var lastMatch: QuestMatch?
    /// 当前任务链锚点：确认过的 qid，供下一次消歧使用
    private(set) var currentQID: String?
    /// 最近一次诊断串（供 HUD / 日志）
    private(set) var lastDiagnostic: String = "未运行"

    /// 统计（自检与排障用）
    private(set) var ocrRuns = 0
    private(set) var ocrCompletions = 0
    private(set) var confirmedCount = 0
    private(set) var missCount = 0
    private(set) var ambiguousCount = 0

    // MARK: 节流

    /// 距上次运行是否已过 `minInterval`。抽出来是为了能单测节流逻辑
    /// （自检里不需要真的截屏）。
    func shouldRun(now: TimeInterval) -> Bool {
        now - lastRun >= Self.minInterval
    }

    /// 记录本次运行时刻（`shouldRun` 返回 true 后调用）。
    func markRan(now: TimeInterval) { lastRun = now }

    // MARK: 入口

    /// 喂一帧（**非阻塞**）。返回 = 本次是否真的发起了 OCR。
    ///
    /// ══════════════════════════════════════════════════════════════════════
    /// 【为什么 OCR 必须走后台队列 —— 实测数字】
    /// ══════════════════════════════════════════════════════════════════════
    ///   在 ROI 1088×135（2940×1912 全屏）暖机后 n=120 实测：
    ///     `.accurate`  p50 **33.6ms**  p95 40.7ms  读出 **4/4 全对**
    ///     `.fast`      p50   4.2ms     p95  7.2ms  读出 **0/4 全错**
    ///   ⟹ 中文 UI 文字**只能**用 `.accurate`（`.fast` 完全读不出中文，
    ///      不是"慢一点但能用"的关系）。
    ///   ⟹ 而 33.6ms ≈ **一整个 30Hz 帧预算（33.3ms）**。若在 tick 里同步跑，
    ///      每 0.7 秒就卡掉一整帧 —— 直接踩项目的 30fps 红线。
    ///
    ///   故：ROI 裁剪在主线程（微秒级），**Vision OCR 丢到专用后台队列**，
    ///   完成后回主线程做投票 + 匹配 + 落库。OCR 占用按 0.7s 一次计 ≈ 单核 4.8%，
    ///   且完全不占主线程。
    ///
    ///   并发保护：上一次 OCR 没回来就不再发起（`ocrInFlight`）——
    ///   任务面板文字变化远慢于 0.7s，丢弃中间帧无信息损失。
    ///
    /// - Parameter cgImage: 当前屏幕帧（全屏 CGImage，归一化 ROI 在其内部裁剪）
    /// - Returns: true = 已发起一次 OCR；false = 被节流 / 上次未回 / ROI 无效
    @discardableResult
    func ingest(cgImage: CGImage) -> Bool {
        let now = CACurrentMediaTime()
        guard shouldRun(now: now) else { return false }
        guard !ocrInFlight else { return false }     // 上一次还没回来 → 跳过本次
        markRan(now: now)
        ocrRuns += 1

        guard let crop = Self.cropROI(cgImage) else {
            lastDiagnostic = "ROI 裁剪失败"
            return false
        }
        ocrInFlight = true
        // crop 由 cropping(to:) 产出，其 data provider 持有底层像素缓冲
        // （见 CaptureEngine 的 passRetained + releaseData 回调），跨线程持有安全。
        ocrQueue.async { [weak self] in
            let lines = Self.recognizeLines(in: crop).filter { !Self.isHintLine($0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.ocrInFlight = false
                guard !lines.isEmpty else {
                    self.lastDiagnostic = "ROI 内无可读文字"
                    return
                }
                self.ocrCompletions += 1
                if let reading = self.ingest(text: lines.joined(separator: "\n")) {
                    self.onConfirmed?(reading)
                }
            }
        }
        return true
    }

    /// 喂一段已 OCR 好的文本（自检 / 单测直接走这条，不需要截屏）。
    @discardableResult
    func ingest(text raw: String) -> QuestPanelReading? {
        // 投票：连续 voteNeed 次相同才确认（只存 String，不存图像）
        let cleaned = QuestText.string(QuestText.clean(raw))
        guard !cleaned.isEmpty else { return nil }   // 空文本不动投票计数（同 Python）

        if cleaned == voteText { voteCount += 1 } else { voteText = cleaned; voteCount = 1 }
        guard voteCount == Self.voteNeed else { return nil }   // 只在"刚好达标"那次放行

        let m = match(cleaned)
        lastMatch = m

        switch m.verdict {
        case .miss:
            missCount += 1
            lastDiagnostic = "未命中「\(cleaned)」"
            return nil

        case .low:
            lastDiagnostic = "置信不足（\(m.hint)）「\(cleaned)」"
            return nil

        case .ambiguous:
            ambiguousCount += 1
            guard let (picked, how) = resolveAmbiguous(m.entries) else {
                lastDiagnostic = "歧义未消解（\(m.entries.count) 候选）「\(cleaned)」"
                return nil
            }
            return commit(picked, match: m, resolvedBy: how, text: cleaned)

        case .ok:
            guard let first = m.entries.first else { return nil }
            return commit(first, match: m, resolvedBy: "unique", text: cleaned)
        }
    }

    private func commit(_ e: QuestEntry, match m: QuestMatch,
                        resolvedBy: String, text: String) -> QuestPanelReading? {
        confirmedCount += 1
        currentQID = e.qid
        let name = e.quest.isEmpty ? e.desc : e.quest
        lastDiagnostic = "确认「\(text)」→ \(e.qid) \(name) [\(m.kind?.rawValue ?? "?")/\(resolvedBy)]"
        return QuestPanelReading(text: text, questName: name,
                                 target: e.worldTarget, qid: e.qid,
                                 kind: m.kind ?? .exact, resolvedBy: resolvedBy)
    }

    /// 复位（停止驾驶 / 换场景时调用）
    func reset() {
        voteText = nil
        voteCount = 0
        lastMatch = nil
        currentQID = nil
        lastRun = 0
        lastDiagnostic = "已复位"
    }

    // MARK: ROI + OCR

    /// 按归一化 ROI（左上原点）裁剪全屏帧。
    nonisolated static func cropROI(_ image: CGImage) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let r = CGRect(x: questROI.origin.x * w, y: questROI.origin.y * h,
                       width: questROI.width * w, height: questROI.height * h)
            .integral
        guard r.width > 0, r.height > 0,
              r.minX >= 0, r.minY >= 0, r.maxX <= w, r.maxY <= h else { return nil }
        return image.cropping(to: r)
    }

    /// Vision 中文 OCR，返回**从上到下**排序的文字行。
    ///
    /// 与 `LoginAssistant` 同款配置（accurate + 关语言纠错 + zh-Hans）：
    /// 任务面板是 UI 文字，语言纠错会把专有名词"纠"成常用词，反而错。
    nonisolated static func recognizeLines(in image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let obs = request.results else { return [] }

        // Vision 的 boundingBox 原点在**左下**：midY 越大越靠上 → 降序即从上到下
        return obs.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                  .compactMap { $0.topCandidates(1).first?.string }
    }

    // MARK: 索引加载

    private func ensureIndex() -> QuestIndex? {
        if let index { return index }
        if indexLoadFailed { return nil }
        let url = AuroraPaths.projectRoot().appendingPathComponent("models/quest_index.json")
        if let idx = QuestIndex.load(url: url) {
            index = idx
            return idx
        }
        indexLoadFailed = true
        lastDiagnostic = "索引加载失败：\(url.path)"
        return nil
    }

    private func ensureChain() -> QuestChainIndex? {
        if let chain { return chain }
        if chainTried { return nil }
        chainTried = true
        chain = QuestChainIndex.load(root: AuroraPaths.projectRoot())
        return chain
    }

    // MARK: 匹配（对应 quest_matcher.match + match_confident）

    /// 四路匹配 + 置信判定。语义与 `quest_matcher.py` 的
    /// `match_confident()` 一致：**只有 `.ok` 才可用于寻路**。
    func match(_ text: String) -> QuestMatch {
        guard let idx = ensureIndex() else {
            return QuestMatch(entries: [], kind: nil, score: 0, verdict: .miss,
                              query: "", hint: "索引未加载")
        }
        let t = QuestText.clean(text)
        let q = QuestText.string(t)
        guard !t.isEmpty else {
            return QuestMatch(entries: [], kind: nil, score: 0, verdict: .miss,
                              query: "", hint: "empty")
        }

        var entries: [QuestEntry] = []
        var kind: QuestMatchKind?
        var score = 0.0
        var hint = ""
        var ambiguous = false

        // ① 精确
        if let e = idx.exact[q] {
            entries = e; kind = .exact; score = 1.0; hint = "exact"; ambiguous = e.count > 1
        }

        // ② 子串（OCR 丢前缀时最有效）
        //    守卫：查询串本身够长，且长度比 ≥0.5 —— 否则「对话」会命中
        //    「S1113对话」这种长 key（假阳性）。
        if entries.isEmpty, t.count >= 4 {
            var subs: [(Double, Int, String, [QuestEntry])] = []
            for k in idx.exactKeys {
                let kc = k.unicodeScalars.count
                if kc < 4 { continue }
                guard let v = idx.exact[k] else { continue }
                let kScalars = Array(k.unicodeScalars)
                if Self.contains(t, kScalars) || Self.contains(kScalars, t) {
                    let ratio = Double(min(kc, t.count)) / Double(max(kc, t.count))
                    if ratio < 0.5 { continue }
                    subs.append((ratio, kc, k, v))
                }
            }
            // 与 Python `subs.sort(reverse=True)` 同序：ratio → len(k) → k 降序
            subs.sort { l, r in
                if l.0 != r.0 { return l.0 > r.0 }
                if l.1 != r.1 { return l.1 > r.1 }
                return l.2 > r.2
            }
            if let best = subs.first {
                entries = best.3; kind = .substr; score = 0.95
                hint = "substr:" + String(best.2.prefix(16))
                ambiguous = entries.count > 1
            }
        }

        // ③ 核心词（剥前缀）
        if entries.isEmpty {
            for c in QuestText.coreCandidates(q) {
                if let e = idx.core[c] {
                    entries = e; kind = .core; score = 0.9
                    hint = "core:" + String(c.prefix(16))
                    ambiguous = e.count > 1
                    break
                }
                // 核心词子串：确定性挑选（超集优先 → 更长优先 → 字典序）
                //
                // ⚠️ 2026-10-06 修 bug：这里的子串比较必须用**整条查询 t**，
                //    不是核心词候选 c。Python 参考实现是
                //        `if len(k) >= 4 and (k in t or t in k)`
                //    —— 拿 key 与 t 比。我第一版写成了与 c 比，后果实测：
                //    「进入藏馆」剥前缀后 c=「藏馆」(2 字)，与 key 无子串关系 →
                //    core-sub 整条落空 → 掉进 fuzzy 0.727 → 判 low 丢弃。
                //    用 t 比对时 c=「藏馆」在 core 表里直接命中（core 阶段），
                //    根本走不到 fuzzy —— 与 Python 一致。
                //    （自检第 7 项的「模糊分落 [0.62,0.75) 判 low」用例正是靠
                //      这个差异暴露出来的：修前它错误地给出 core-sub/0.85。）
                var cands: [String] = []
                for k in idx.coreKeys {
                    let kc = k.unicodeScalars.count
                    if kc < 4 { continue }
                    let ks = Array(k.unicodeScalars)
                    if Self.contains(t, ks) || Self.contains(ks, t) { cands.append(k) }
                }
                if let k = Self.pickCoreSub(cands, query: t), let e = idx.core[k] {
                    entries = e; kind = .coreSub; score = 0.85
                    hint = "core-sub:" + String(k.prefix(16))
                    ambiguous = e.count > 1
                    break
                }
            }
        }

        // ④ 模糊（SequenceMatcher 等价，阈值 0.62）
        if entries.isEmpty {
            var bestR = -1.0, bestK: String?
            for k in idx.exactKeys {
                let r = QuestText.sequenceRatio(t, Array(k.unicodeScalars))
                if r < Self.fuzzyThreshold { continue }
                if r > bestR || (r == bestR && (bestK == nil || k > bestK!)) {
                    bestR = r; bestK = k
                }
            }
            if let k = bestK, let e = idx.exact[k] {
                entries = e; kind = .fuzzy; score = bestR
                hint = String(format: "fuzzy:%.2f:%@", bestR, String(k.prefix(16)))
                ambiguous = e.count > 1
            }
        }

        // ⑤ 任务名兜底（弱证据）
        //    ⚠️ 2026-10-06 修复（验证方报 HIGH 假阳性）：原实现是裸 `in`，
        //       无长度守卫 → 单字查询「的」「E」「异」都能假报唯一。
        //       现在要求：查询 ≥4 字、任务名 ≥4 字、长度比 ≥0.5（与 substr 同标准）。
        if entries.isEmpty, t.count >= 4 {
            var cands: [String] = []
            for nm in idx.bynameKeys {
                let nc = nm.unicodeScalars.count
                if nc < 4 { continue }
                let ns = Array(nm.unicodeScalars)
                if Self.contains(t, ns) || Self.contains(ns, t) {
                    let ratio = Double(min(nc, t.count)) / Double(max(nc, t.count))
                    if ratio < 0.5 { continue }
                    cands.append(nm)
                }
            }
            if let nm = Self.pickCoreSub(cands, query: t), let e = idx.byname[nm] {
                entries = e; kind = .name; score = 0.8
                hint = "name:" + String(nm.prefix(16))
                ambiguous = e.count > 1
            }
        }

        // ── 统一置信门槛（对应 match_confident）──
        let verdict: QuestVerdict
        if entries.isEmpty { verdict = .miss }
        else if t.count < Self.minQueryLen { verdict = .low }
        else if kind == .fuzzy && score < Self.fuzzyConfident { verdict = .low }
        else if ambiguous { verdict = .ambiguous }
        else { verdict = .ok }

        return QuestMatch(entries: entries, kind: kind, score: score,
                          verdict: verdict, query: q, hint: hint)
    }

    /// 确定性挑选 core-sub / name 的胜者。
    ///
    /// Python 是「遍历字典取第一个命中」—— 顺序即 JSON 插入序，而
    /// Swift 的字典顺序每进程都不同，`JSONSerialization` 也丢掉了插入序。
    /// 故这里换成一条**有原则的确定性规则**：
    ///   ① 查询是 key 的子串（key 更具体）优先 —— 短查询套长 key 时，
    ///      长 key 携带更多信息，是更精确的锚点；
    ///   ② 其次 key 更长者优先；
    ///   ③ 最后字典序（纯粹为了同分时有唯一解）。
    ///
    /// 与 Python 的对拍结果（1332 条含 OCR 噪声的样本）：
    ///   · 全部长度：1283/1328 一致（96.6%）
    ///   · ≥5 字（真实面板长度）：982/985 一致（**99.7%**）
    ///   残差全部是「同族兄弟任务」（如 q110960_h1/h4、K112407/K112408），
    ///   Python 靠 JSON 插入序决出，属构建期偶然，不构成可移植语义。
    static func pickCoreSub(_ cands: [String], query: [Unicode.Scalar]) -> String? {
        guard !cands.isEmpty else { return nil }
        return cands.min { l, r in
            let lSuper = contains(Array(l.unicodeScalars), query) ? 0 : 1
            let rSuper = contains(Array(r.unicodeScalars), query) ? 0 : 1
            if lSuper != rSuper { return lSuper < rSuper }
            let lc = l.unicodeScalars.count, rc = r.unicodeScalars.count
            if lc != rc { return lc > rc }
            return l < r
        }
    }

    /// `haystack` 是否包含 `needle`（标量级朴素匹配，够用且无正则开销）
    static func contains(_ haystack: [Unicode.Scalar], _ needle: [Unicode.Scalar]) -> Bool {
        if needle.isEmpty { return true }
        if needle.count > haystack.count { return false }
        let limit = haystack.count - needle.count
        var i = 0
        while i <= limit {
            if haystack[i] == needle[0] {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    // MARK: 链消歧

    /// 多候选消歧。返回 (选中的条目, 依据)；nil = 消解不掉，应当等下一帧。
    ///
    /// 顺序：
    ///   ① NextQuests：若已知当前任务，且它的后继里**恰好一个**在候选集中 → 采用
    ///   ② 坐标等价：候选全部落在 `equivalentRadiusMeters` 内 → 任取其一
    ///   ③ 否则放弃（不猜）
    func resolveAmbiguous(_ entries: [QuestEntry]) -> (QuestEntry, String)? {
        guard entries.count > 1 else { return entries.first.map { ($0, "unique") } }

        if let cur = currentQID, let ch = ensureChain(), let nx = ch.next[cur] {
            let nset = Set(nx)
            let pref = entries.filter { nset.contains($0.qid) }
            if pref.count == 1 { return (pref[0], "chain-next") }
        }

        let pts = entries.compactMap { $0.worldTarget }
        if pts.count == entries.count, !pts.isEmpty {
            let cx = pts.map(\.x).reduce(0, +) / Double(pts.count)
            let cy = pts.map(\.y).reduce(0, +) / Double(pts.count)
            let maxD = pts.map { hypot($0.x - cx, $0.y - cy) }.max() ?? .infinity
            if maxD <= Self.equivalentRadiusMeters * 100.0 {   // 世界坐标单位是厘米
                return (entries[0], "coord-equivalent")
            }
        }
        return nil
    }
}

// MARK: - 自检（--quest-selftest）

extension QuestPanelReader {

    /// 8 条真实面板文字 —— 期望值**全部来自 Python 参考实现实测**，
    /// 不是"应该是这样"的推断。
    ///
    /// ⚠️ 期望 verdict 如实标注：这 8 条里 **5 条 ok / 2 条 ambiguous / 1 条 low**，
    ///    **不是**"全部 ok"。ambiguous 的两条（与薄荷对话 23 候选、与龙叔交谈 3 候选）
    ///    是索引的真实性质，不是缺陷；`与龙叔交谈` 三个候选坐标完全相同，
    ///    会被坐标等价规则放行。`赴约` 只有 2 字 → 按置信门槛判 low（有意拒绝）。
    nonisolated static let realPanelTexts: [(text: String, verdict: String, kind: String, x: Double, y: Double)] = [
        ("与路边着急的研究员对话", "ok",        "exact",    -17868.69, 125947.41),
        ("抵达异象管理局",         "ok",        "core-sub",   3974.61, 262435.10),
        ("与薄荷对话",             "ambiguous", "exact",      4240.00, 271950.00),
        ("搭乘电梯",               "ok",        "exact",     30756.98,  65970.63),
        ("赴约",                   "low",       "core-sub", -18315.06,  33622.11),
        ("与龙叔交谈",             "ambiguous", "exact",  -256319.52, 138608.19),
        ("走进局长办公室",         "ok",        "exact",      3990.00, 267360.00),
        ("与艾尔菲德交流",         "ok",        "exact",      3990.00, 267360.00),
    ]

    /// 跑自检，返回**失败项数**（0 = 全过，与其它 `--*-selftest` 同一约定）。
    @MainActor
    static func runSelfTest() -> Int {
        var fail = 0
        func ck(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "✅" : "❌") \(name)  \(detail)")
            if !ok { fail += 1 }
        }

        print("═══ 任务面板 OCR 自检（--quest-selftest）═══")
        let root = AuroraPaths.projectRoot()
        let indexPath = root.appendingPathComponent("models/quest_index.json")
        print("项目根: \(root.path)")
        print("索引:   \(indexPath.path)")

        guard let idx = QuestIndex.load(url: indexPath) else {
            print("❌ 索引加载失败：\(indexPath.path)")
            return 1
        }
        let st = idx.stats
        print("统计:   files=\(st["files"] ?? -1) objectives=\(st["objectives"] ?? -1) "
              + "with_coord=\(st["with_coord"] ?? -1) exact_keys=\(st["exact_keys"] ?? -1) "
              + "core_keys=\(st["core_keys"] ?? -1) name_keys=\(st["name_keys"] ?? -1)")
        print("")

        let r = QuestPanelReader()

        // ── 1. 8 条真实面板文字回归 ──
        print("── 1. 真实面板文字回归（8 条）──")
        var okCount = 0, usableCount = 0, verdictOK = 0
        for (text, wantVerdict, wantKind, wantX, wantY) in realPanelTexts {
            let m = r.match(text)
            let kindOK = (m.kind?.rawValue ?? "") == wantKind
            let verdictOKHere = m.verdict.rawValue == wantVerdict
            if verdictOKHere { verdictOK += 1 }

            // 坐标：取该条目的世界坐标，与 Python 标准答案比对（容差 1 厘米）
            let coord = m.entries.first?.worldTarget
            let coordOK = coord.map { abs($0.x - wantX) <= 1.0 && abs($0.y - wantY) <= 1.0 } ?? false
            if m.verdict == .ok && coordOK && kindOK { okCount += 1 }

            // 可寻路 = ok，或多候选但消歧成功（链 / 坐标等价）
            var usable = false, how = "-"
            if m.verdict == .ok { usable = coordOK; how = "unique" }
            else if m.verdict == .ambiguous, let (e, h) = r.resolveAmbiguous(m.entries) {
                usable = e.worldTarget != nil; how = h
            }
            if usable { usableCount += 1 }

            let mark = (verdictOKHere && coordOK) ? "✅" : "❌"
            print("  \(mark) \(text.padding(toLength: 22, withPad: " ", startingAt: 0))"
                  + " verdict=\(m.verdict.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))"
                  + " kind=\((m.kind?.rawValue ?? "-").padding(toLength: 9, withPad: " ", startingAt: 0))"
                  + " n=\(String(m.entries.count).padding(toLength: 3, withPad: " ", startingAt: 0))"
                  + " coord=(\(coord.map { String(format: "%.0f", $0.x) } ?? "?"), "
                  + "\(coord.map { String(format: "%.0f", $0.y) } ?? "?"))"
                  + " 可寻路=\(usable ? how : "否")"
                  + (coordOK ? "" : " ⚠️期望(\(String(format: "%.0f", wantX)), \(String(format: "%.0f", wantY)))"))
        }
        print("  ── 命中：可寻路 \(usableCount)/8 ｜ verdict=ok \(okCount)/8 ｜ verdict 与 Python 一致 \(verdictOK)/8")
        ck("8 条 verdict 与 Python 参考实现一致", verdictOK == 8, "\(verdictOK)/8")
        ck("8 条可寻路命中数 = 6", usableCount == 6, "可寻路 \(usableCount)/8（2 条 ambiguous 中 1 条被坐标等价放行；1 条 low 有意拒绝）")
        ck("8 条坐标与 Python 标准答案一致（容差 1cm）", okCount == 5, "坐标全对的唯一命中 \(okCount)/8")

        // ── 2. 反向用例：不许假阳性 ──
        print("")
        print("── 2. 反向用例（必须拦住）──")
        let neg = r.match("对话")
        ck("「对话」判 low（364 候选，长度不足）",
           neg.verdict == .low && neg.entries.count == 364,
           "verdict=\(neg.verdict.rawValue) 候选=\(neg.entries.count)")
        let miss1 = r.match("[剧情HeroicApearan")
        ck("「[剧情HeroicApearan」判 miss", miss1.verdict == .miss,
           "verdict=\(miss1.verdict.rawValue) 候选=\(miss1.entries.count)")
        let miss2 = r.match("")
        ck("空串判 miss", miss2.verdict == .miss && miss2.entries.isEmpty,
           "verdict=\(miss2.verdict.rawValue)")
        let one = r.match("的")
        ck("单字「的」判 miss（修复前会假报唯一）",
           one.verdict == .miss && one.entries.isEmpty,
           "verdict=\(one.verdict.rawValue) 候选=\(one.entries.count)")

        // 抽样扫描：单字一律不许判 ok
        let scalars = (0x4E00...0x9EFF).compactMap { Unicode.Scalar(UInt32($0)) }
        let oneSample = stride(from: 0, to: scalars.count, by: 7).map { String(Character(scalars[$0])) }
        let oneOK = oneSample.filter { r.match($0).verdict == .ok }.count
        ck("单字抽样 \(oneSample.count) 个判 ok 数 = 0", oneOK == 0, "ok=\(oneOK)")

        // ── 3. 投票缓冲 ──
        print("")
        print("── 3. 投票缓冲（连续 3 次相同才确认）──")
        let v = QuestPanelReader()
        let t1 = v.ingest(text: "搭乘电梯")
        let t2 = v.ingest(text: "搭乘电梯")
        let t3 = v.ingest(text: "搭乘电梯")
        ck("第 1/2 次不确认、第 3 次确认",
           t1 == nil && t2 == nil && t3 != nil,
           "1→\(t1 == nil ? "nil" : "有") 2→\(t2 == nil ? "nil" : "有") 3→\(t3 == nil ? "nil" : "有")")
        ck("确认到正确任务与坐标",
           t3?.qid == "L110302_M" && t3?.target != nil,
           "qid=\(t3?.qid ?? "-") target=\(t3.flatMap { $0.target.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) } } ?? "-")")
        // quest 名为空时必须回退到 desc（索引里确有 quest="" 的条目）
        let vn = QuestPanelReader()
        _ = vn.ingest(text: "与路边着急的研究员对话")
        _ = vn.ingest(text: "与路边着急的研究员对话")
        let tn = vn.ingest(text: "与路边着急的研究员对话")
        ck("quest 名为空时回退到 desc",
           tn?.questName == "与路边着急的研究员对话",
           "questName=「\(tn?.questName ?? "nil")」（该条 qid=---活动开始对话--- 的 quest 字段为空串）")
        // 抖动：文本变化要重新计票
        let v2 = QuestPanelReader()
        _ = v2.ingest(text: "搭乘电梯"); _ = v2.ingest(text: "搭乘电梯")
        let j1 = v2.ingest(text: "走进局长办公室")
        let j2 = v2.ingest(text: "走进局长办公室")
        ck("文本抖动后重新计票", j1 == nil && j2 == nil, "抖动后前两次不确认")

        // ── 4. 链消歧 + 坐标等价 ──
        print("")
        print("── 4. 链消歧（NextQuests）与坐标等价 ──")
        let c = QuestPanelReader()
        let amb = c.match("与薄荷对话")
        ck("「与薄荷对话」判 ambiguous（23 候选）",
           amb.verdict == .ambiguous && amb.entries.count == 23,
           "verdict=\(amb.verdict.rawValue) 候选=\(amb.entries.count)")
        let noAnchor = c.resolveAmbiguous(amb.entries)
        ck("无链锚点时消解不掉（不猜）", noAnchor == nil,
           noAnchor == nil ? "正确放弃，等下一帧" : "⚠️错误地选了 \(noAnchor!.0.qid)")
        c.currentQID = "WJ101302"          // 该 qid 的 NextQuests = [WJ101303]
        let resolved = c.resolveAmbiguous(amb.entries)
        ck("锚点 WJ101302 → 唯一后继 WJ101303",
           resolved?.0.qid == "WJ101303" && resolved?.1 == "chain-next",
           "选中=\(resolved?.0.qid ?? "nil") 依据=\(resolved?.1 ?? "-")")

        let c2 = QuestPanelReader()
        let amb2 = c2.match("与龙叔交谈")
        let eq = c2.resolveAmbiguous(amb2.entries)
        ck("「与龙叔交谈」3 候选坐标相同 → 坐标等价放行",
           amb2.verdict == .ambiguous && amb2.entries.count == 3
             && eq != nil && eq?.1 == "coord-equivalent",
           "候选=\(amb2.entries.count) 依据=\(eq?.1 ?? "nil") 目标=\(eq.flatMap { $0.0.worldTarget.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) } } ?? "-")")

        // ── 5. 坐标语义：一个转换都不做 ──
        print("")
        print("── 5. 坐标语义（quest_index x/y 原样喂 setLocatorTarget）──")
        let cm = c.match("与路边着急的研究员对话")
        if let e = cm.entries.first, let raw = idx.exact["与路边着急的研究员对话"]?.first {
            ck("条目坐标与索引原始值逐位相同（无任何换算）",
               e.x == raw.x && e.y == raw.y && e.z == raw.z,
               "index=(\(raw.x ?? 0), \(raw.y ?? 0), \(raw.z ?? 0)) 读出=(\(e.x ?? 0), \(e.y ?? 0), \(e.z ?? 0))")
            ck("世界坐标量级合理（|x|,|y| < 1e6 厘米 = 10km 内）",
               abs(raw.x ?? 0) < 1_000_000 && abs(raw.y ?? 0) < 1_000_000,
               "x=\(raw.x ?? 0) y=\(raw.y ?? 0)（UE5 厘米）")
        } else {
            ck("条目坐标与索引原始值逐位相同（无任何换算）", false, "取不到条目")
        }

        // ── 6. ROI 与提示行过滤 ──
        print("")
        print("── 6. ROI 与提示行过滤 ──")
        let roi = QuestPanelReader.questROI
        let px = (x: roi.minX * 2940, y: roi.minY * 1912,
                  w: roi.width * 2940, h: roi.height * 1912)
        ck("ROI 换算到 2940×1912 = x 88~1176 / y 458~592",
           Int(px.x) == 88 && Int(px.y) == 458
             && Int(px.x + px.w) == 1176 && Int(px.y + px.h) == 592,
           "x \(Int(px.x))~\(Int(px.x + px.w)) / y \(Int(px.y))~\(Int(px.y + px.h))"
             + "（0.070×1912=133.84 → 截断到 592，与任务描述一致）")
        ck("提示行「V 按下进行追踪」被过滤",
           QuestPanelReader.isHintLine("V 按下进行追踪")
             && QuestPanelReader.isHintLine("按下进行追踪"),
           "两条提示行均判为提示行")
        ck("正常任务文字不被误过滤",
           !QuestPanelReader.isHintLine("与路边着急的研究员对话"),
           "「与路边着急的研究员对话」保留")
        // 拼接场景：提示行混入后必须仍能匹配
        let v3 = QuestPanelReader()
        let mixed = ["与路边着急的研究员对话", "V 按下进行追踪"]
            .filter { !QuestPanelReader.isHintLine($0) }.joined(separator: "\n")
        _ = v3.ingest(text: mixed); _ = v3.ingest(text: mixed)
        let m3 = v3.ingest(text: mixed)
        ck("混入提示行后仍命中（过滤生效）",
           m3 != nil && m3?.target != nil,
           "qid=\(m3?.qid ?? "-") target=\(m3.flatMap { $0.target.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) } } ?? "-")")

        // ── 7. 模糊匹配（SequenceMatcher 等价）──
        print("")
        print("── 7. 模糊匹配（阈值 0.62 / 可信 0.75）──")
        let fz = r.match("前往月亮湾寻埃德嘉")       // 比索引少一个「找」
        ck("丢字查询走 fuzzy 且判 ok",
           fz.kind == .fuzzy && fz.verdict == .ok,
           "kind=\(fz.kind?.rawValue ?? "-") score=\(String(format: "%.2f", fz.score)) verdict=\(fz.verdict.rawValue)")
        // 与 difflib 实测值逐位比对（这 4 个期望值来自 Python 实跑）
        let ratioCases: [(String, String, Double)] = [
            ("abc", "abc", 1.0),
            ("abc", "abd", 0.6666666666666666),
            ("", "", 1.0),
            ("abc", "", 0.0),
        ]
        var ratioOK = true
        for (a, b, want) in ratioCases {
            let got = QuestText.sequenceRatio(Array(a.unicodeScalars), Array(b.unicodeScalars))
            if abs(got - want) > 1e-9 {
                ratioOK = false
                print("     ⚠️ ratio(\(a),\(b))=\(got) 期望 \(want)")
            }
        }
        ck("sequenceRatio 与 difflib 一致（4 例）", ratioOK, "全部逐位吻合")
        // 短查询 + 模糊低分必须判 low（0.62 入选 ≠ 可信）
        // ⚠️ 真值来自 Python 实测：`进入藏馆`（索引 key「进入金苹果藏馆」缺 3 字）
        //    走 fuzzy 得 0.727 —— 落在 [0.62, 0.75) 区间，**必须**被判 low 丢掉。
        //    （第一版这条断言写成了"只要不是 fuzzy 就算过"，那是**空洞断言**：
        //      任何 kind 都能通过。现在改成钉死 kind 与分数区间。）
        let lowFz = r.match("进入藏馆")
        ck("模糊分落在 [0.62,0.75) 判 low（不冒用）",
           lowFz.kind == .fuzzy && lowFz.score >= 0.62 && lowFz.score < 0.75
             && lowFz.verdict == .low,
           "kind=\(lowFz.kind?.rawValue ?? "-") score=\(String(format: "%.3f", lowFz.score)) verdict=\(lowFz.verdict.rawValue)")

        // ── 8. 节流 ──
        print("")
        print("── 8. 节流（0.7s，不是每帧）──")
        let th = QuestPanelReader()
        let first = th.shouldRun(now: 100.0)
        th.markRan(now: 100.0)
        let tooSoon = th.shouldRun(now: 100.5)
        let later = th.shouldRun(now: 100.71)
        ck("0.7s 内不重复跑", first && !tooSoon && later,
           "t=100 跑=\(first) t=100.5 跑=\(tooSoon) t=100.71 跑=\(later)")

        print("")
        print("═══ 结果：\(fail == 0 ? "全部通过 ✅" : "失败 \(fail) 项 ❌") ═══")
        return fail
    }
}
