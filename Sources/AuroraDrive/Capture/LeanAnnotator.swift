// SPDX-License-Identifier: Apache-2.0
//
// LeanAnnotator.swift
// 精简录制的**离线**标注器。
//
// 【为什么要单独成一个子进程，而不是在 UI 进程里跑】
//   速度 OCR 走 `SpeedOCRReader.recognizeDirectory`，那是 @MainActor 的同步全量循环。
//   10 分钟素材 9000 帧、每帧几毫秒，在 UI 进程里直接跑会冻结界面几十秒 ——
//   而用户要求的是「离线后台处理」。子进程有独立地址空间、独立模型、独立主线程，
//   既能真后台跑，也不会和抓屏/推理抢主线程。
//
// 【它做什么】
//   1) 速度 OCR：对 `frames/*.jpg` 逐帧识别速度表，回填 `controls.csv` 的 speed_kmh 列。
//   2) 按键整理：统计全零帧、极致刹车列一致性（只统计，不改按键 —— 按键是原生标签，
//      由录制时的物理键盘状态决定，标注阶段**不允许**篡改，否则标签就不是"原生"了）。
//   3) 质量检查：帧率、帧数/行数一致性、定位缺失、速度跳变、识别覆盖率。
//   4) 产出 `annotate_report.json`。
//
// 【为什么只回填 speed_kmh，不动别的列】
//   `dataset_v3` 对空串判 `speed_valid=0`（不拿 0 当速度），所以"没识别出来"必须保持空串；
//   而定位/按键在录制时就是权威值，标注阶段重算只会引入新错误。
//
// 【写盘安全】
//   回填是"整表重写"，但先写 `controls.csv.tmp` 再 `replaceItemAt` 原子替换：
//   中途崩溃只会留下 tmp，原 CSV 不会被截断成半个文件。
//   写之前还校 `frame` 列必须等于数据行序号 —— 这是 `dataset_v3._read_rows` 的硬约束，
//   一旦错位就应该**拒绝写**，而不是把错位数据写进去。

import Darwin
import Foundation

enum LeanAnnotator {

    /// 标注质量报告（写入 clip 目录下的 `annotate_report.json`）
    struct Report: Codable {
        var clip: String
        var annotatedAt: String
        var rows: Int
        var frameFiles: Int
        var fpsMeasured: Double?
        var speedFilled: Int
        var speedMissing: Int
        var speedFillRatio: Double
        /// 相邻两帧识别速度跳变超过 20km/h 的次数（OCR 误读的强信号）
        var speedJumpsOver20: Int
        var keyAllZeroFrames: Int
        var poseMissingRows: Int
        var verdict: String
        var notes: [String]
    }

    /// CSV 里我们依赖的列名（其余列原样保留，不假设列数）
    private static let speedColumnName = "speed_kmh"
    private static let frameColumnName = "frame"
    private static let requiredColumns = ["t_sec", "frame", "speed_kmh",
                                          "w", "a", "s", "d", "shift", "space",
                                          "super_brake", "ultimate_brake"]

    // MARK: - 入口

    /// 跑一次离线标注。
    /// - Parameter emitProgress: true 时向 stdout 发 `PROGRESS|<阶段>|<0~1>` 行，
    ///   父进程（UI）靠它更新进度条。用 FileHandle 直写而不是 `print`：
    ///   stdout 接管道时 libc 默认全缓冲，`print` 的内容要等进程退出才吐出来，
    ///   进度条就会在标注全程保持 0%，最后一下跳到 100%。
    /// - Returns: 进程退出码（0 = 通过/警告，2 = 输入错误，3 = 质量不合格）
    @MainActor
    static func run(clipDirPath: String, emitProgress: Bool) -> Int32 {
        let clip = URL(fileURLWithPath: clipDirPath)
        let fm = FileManager.default
        var notes: [String] = []

        func emit(_ stage: String, _ pct: Double) {
            guard emitProgress else { return }
            let line = String(format: "PROGRESS|%@|%.4f\n", stage, min(max(pct, 0), 1))
            FileHandle.standardOutput.write(line.data(using: .utf8) ?? Data())
        }
        func fail(_ msg: String, code: Int32) -> Int32 {
            emit("失败", 1)
            FileHandle.standardError.write(("✗ " + msg + "\n").data(using: .utf8) ?? Data())
            return code
        }

        let csvURL = clip.appendingPathComponent("controls.csv")
        let framesURL = clip.appendingPathComponent("frames")
        guard fm.fileExists(atPath: csvURL.path) else {
            return fail("缺少 controls.csv: \(csvURL.path)", code: 2)
        }
        guard fm.fileExists(atPath: framesURL.path) else {
            return fail("缺少 frames/ 目录: \(framesURL.path)", code: 2)
        }

        // ── 1. 读 CSV 并校验表头 ────────────────────────────────────────
        emit("读取", 0.02)
        guard let csvText = try? String(contentsOf: csvURL, encoding: .utf8) else {
            return fail("controls.csv 无法按 UTF-8 读取", code: 2)
        }
        var lines = csvText.components(separatedBy: "\n")
        // 末行空串是结尾换行造成的，不是数据行
        if lines.last == "" { lines.removeLast() }
        guard let headerLine = lines.first else {
            return fail("controls.csv 是空文件", code: 2)
        }
        let header = headerLine.components(separatedBy: ",")
        guard let speedCol = header.firstIndex(of: speedColumnName) else {
            return fail("controls.csv 缺少 \(speedColumnName) 列（表头: \(headerLine)）", code: 2)
        }
        guard let frameCol = header.firstIndex(of: frameColumnName) else {
            return fail("controls.csv 缺少 \(frameColumnName) 列", code: 2)
        }
        let missingCols = requiredColumns.filter { !header.contains($0) }
        guard missingCols.isEmpty else {
            return fail("controls.csv 缺少必需列 \(missingCols)（V3 数据集会拒绝加载）", code: 2)
        }
        let colCount = header.count
        let dataLines = Array(lines.dropFirst())

        // ── 1.5 帧文件完整性（**必须在任何写盘之前**）──────────────────────
        // 【为什么不能等质检那步】回填用「文件名数字 → 帧号」映射速度，却按**行号**
        //   写回 CSV。一旦 frames/ 有洞（缺帧、人工删帧、半成品），文件号 ≠ 行号，
        //   速度就被写到**错误的行**上；而原先这条校验排在原子替换**之后**，
        //   等于先把错误数据固化、再报告失败。拒绝胜于固化。
        // 判据不是"数量相等"而是"编号集合恰好 0..<total"：数量相等也可能错位。
        let frameFilesOnDisk = ((try? fm.contentsOfDirectory(atPath: framesURL.path))?
            .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") }) ?? []
        let frameIndexes = Set(frameFilesOnDisk.compactMap {
            Int(($0 as NSString).deletingPathExtension)
        })
        if frameIndexes != Set(0..<dataLines.count) {
            return fail("frames/ 的帧编号不连续（应有 0..<\(dataLines.count) 共 \(dataLines.count) 张，"
                        + "实际 \(frameFilesOnDisk.count) 张）——回填会把速度写到错行，已拒绝",
                        code: 2)
        }

        // ── 2. 校验「第 i 个数据行 frame == i」这条硬约束 ────────────────
        // 不满足就直接退出：此时回填会把错位数据固化，比不标注糟糕得多。
        emit("校验", 0.05)
        for (i, line) in dataLines.enumerated() {
            let cols = line.components(separatedBy: ",")
            guard cols.count == colCount else {
                return fail("第 \(i) 个数据行列数 \(cols.count) ≠ 表头 \(colCount)", code: 2)
            }
            guard let frameValue = Int(cols[frameCol]), frameValue == i else {
                return fail("第 \(i) 个数据行 frame=\(cols[frameCol])，与行序不符"
                            + "（dataset_v3 会拒绝加载）", code: 2)
            }
        }

        // ── 3. 速度 OCR ────────────────────────────────────────────────
        emit("速度OCR", 0.10)
        let reader = SpeedOCRReader()
        let total = dataLines.count
        let results = reader.recognizeDirectory(framesURL.path) { done, all in
            // 10% → 80% 用于 OCR
            let frac = all > 0 ? Double(done) / Double(all) : 1
            emit("速度OCR", 0.10 + 0.70 * frac)
        }
        guard !results.isEmpty else {
            return fail("速度 OCR 未产出任何结果（模型未加载或 frames/ 为空）", code: 3)
        }

        // 文件名 → 帧号（`frames/000123.jpg` → 123），与 CSV 行序对齐的**唯一**依据
        var speedByFrame: [Int: Int] = [:]
        for r in results {
            guard let idx = Int((r.name as NSString).deletingPathExtension),
                  let sp = r.speed, sp >= SpeedOCRReader.minSpeed, sp <= SpeedOCRReader.maxSpeed
            else { continue }
            speedByFrame[idx] = sp
        }

        // ── 4. 回填 speed_kmh 列 ───────────────────────────────────────
        emit("回填", 0.82)
        var newLines: [String] = []
        newLines.reserveCapacity(lines.count)
        newLines.append(headerLine)
        var speedFilled = 0
        var speedMissing = 0
        var keyAllZero = 0
        var poseMissing = 0
        var lastSpeed: Int?
        var jumps = 0
        let wCol = header.firstIndex(of: "w"), aCol = header.firstIndex(of: "a")
        let sCol = header.firstIndex(of: "s"), dCol = header.firstIndex(of: "d")
        let shiftCol = header.firstIndex(of: "shift"), spaceCol = header.firstIndex(of: "space")
        let xCol = header.firstIndex(of: "x")
        var tSec: [Double] = []
        let tCol = header.firstIndex(of: "t_sec")

        for (i, line) in dataLines.enumerated() {
            var cols = line.components(separatedBy: ",")
            if let sp = speedByFrame[i] {
                cols[speedCol] = String(sp)
                speedFilled += 1
                if let prev = lastSpeed, abs(sp - prev) > 20 { jumps += 1 }
                lastSpeed = sp
            } else {
                // 保持空串：dataset_v3 据此判 speed_valid=0，不会把缺值当 0 速
                cols[speedCol] = ""
                speedMissing += 1
            }
            // 按键全零帧（数据集会 skip_all_zero，统计它是为了告知"这段路没按键"）
            if let w = wCol, let a = aCol, let s = sCol, let d = dCol,
               let sh = shiftCol, let spc = spaceCol,
               cols[w] == "0", cols[a] == "0", cols[s] == "0",
               cols[d] == "0", cols[sh] == "0", cols[spc] == "0" {
                keyAllZero += 1
            }
            // 定位缺失（缺 pcap 时录制器写空串，这里统计覆盖率）
            if let xc = xCol, cols[xc].isEmpty { poseMissing += 1 }
            if let tc = tCol, tc < cols.count, let t = Double(cols[tc]) { tSec.append(t) }
            newLines.append(cols.joined(separator: ","))
        }

        // ── 5. 原子替换写回 ───────────────────────────────────────────
        let tmpURL = clip.appendingPathComponent("controls.csv.tmp")
        let outText = newLines.joined(separator: "\n") + "\n"
        guard let outData = outText.data(using: .utf8) else {
            return fail("回填结果编码失败", code: 2)
        }
        do {
            try outData.write(to: tmpURL, options: .atomic)
            _ = try fm.replaceItemAt(csvURL, withItemAt: tmpURL)
        } catch {
            try? fm.removeItem(at: tmpURL)
            return fail("controls.csv 回填写盘失败: \(error.localizedDescription)", code: 2)
        }

        // ── 6. 质量检查 + 报告 ────────────────────────────────────────
        emit("质检", 0.94)
        var fps: Double? = nil
        if tSec.count >= 3 {
            let dts = zip(tSec.dropFirst(), tSec).map { $0 - $1 }.filter { $0 > 0 }
            if !dts.isEmpty {
                let sorted = dts.sorted()
                let median = sorted[sorted.count / 2]
                if median > 0 { fps = 1.0 / median }
            }
        }
        let frameFiles = (try? fm.contentsOfDirectory(atPath: framesURL.path))?
            .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") }
            .count ?? 0

        let ratio = total > 0 ? Double(speedFilled) / Double(total) : 0
        var verdict = "pass"
        if total == 0 {
            verdict = "fail"
            notes.append("没有数据行")
        } else if frameFiles != total {
            verdict = "fail"
            notes.append("行数 \(total) ≠ 帧文件数 \(frameFiles)（dataset_v3 会按行找帧）")
        } else if ratio < 0.5 {
            verdict = "fail"
            notes.append(String(format: "速度识别覆盖率仅 %.1f%%，画面可能没有速度表", ratio * 100))
        } else if ratio < 0.90 {
            verdict = "warn"
            notes.append(String(format: "速度识别覆盖率 %.1f%%", ratio * 100))
        }
        if let f = fps, abs(f - 15.0) > 15.0 * 0.15 {
            // 帧率问题会让 dataset_v3 直接抛 ValueError，必须提前暴露
            verdict = "fail"
            notes.append(String(format: "实测帧率 %.2ffps，超出 V3 的 15fps±15%%", f))
        }
        if poseMissing == total {
            notes.append("全部帧缺定位（pcap 未抓到）")
        }
        if jumps > 0 {
            notes.append("速度跳变 >20km/h 共 \(jumps) 次，建议抽查")
        }
        if keyAllZero == total {
            notes.append("全部帧无按键 —— dataset_v3 会 skip_all_zero 后没有样本")
        }

        let report = Report(
            clip: clip.lastPathComponent,
            annotatedAt: ISO8601DateFormatter().string(from: Date()),
            rows: total,
            frameFiles: frameFiles,
            fpsMeasured: fps,
            speedFilled: speedFilled,
            speedMissing: speedMissing,
            speedFillRatio: ratio,
            speedJumpsOver20: jumps,
            keyAllZeroFrames: keyAllZero,
            poseMissingRows: poseMissing,
            verdict: verdict,
            notes: notes)

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let reportURL = clip.appendingPathComponent("annotate_report.json")
        if let rdata = try? enc.encode(report) {
            try? rdata.write(to: reportURL, options: .atomic)
        }

        emit("完成", 1.0)
        let summary = String(format: "标注完成 %@：%d 行，速度回填 %d（%.1f%%），帧率 %@，判定 %@",
                             clip.lastPathComponent, total, speedFilled, ratio * 100,
                             fps.map { String(format: "%.2f", $0) } ?? "未知",
                             verdict)
        FileHandle.standardError.write((summary + "\n").data(using: .utf8) ?? Data())
        for n in notes { FileHandle.standardError.write(("  · " + n + "\n").data(using: .utf8) ?? Data()) }

        return verdict == "fail" ? 3 : 0
    }
}

/// 标注子进程的运行器：UI 侧只管拉起/收进度/收结果。
///
/// 【为什么子进程而不是同进程后台队列】
///   见本文件头部注释 —— 速度 OCR 是 @MainActor 同步全量循环，同进程跑必然冻界面。
///   子进程还有额外好处：模型加载失败/OOM 崩掉不会拖倒正在跑的主程序。
///
/// 【为什么必须把两条管道都读干】
///   子进程往 stderr 写汇总信息。若父进程不读，管道缓冲写满后子进程会**永久阻塞**在
///   写 stderr 上，表现为"标注永远不结束"。故 stderr 也挂 readabilityHandler 持续抽走。
/// 管道文本缓冲：**只被后台 readabilityHandler 触碰**的纯数据。
///
/// 【为什么单独成类】`readabilityHandler` 由系统在后台队列回调，而 runner 是
///   @MainActor。把 stdout 残行 / stderr 尾部直接放 runner 里，后台回调就得跨
///   actor 改主线程隔离状态（Swift 6 语言模式下是错误，现在也已报 6 条警告）。
///   收进这里后：盒内自带 NSLock 保证线程安全，盒外只暴露 Sendable 方法 ——
///   这正是 `@unchecked Sendable` 的正当用法（安全性由内部锁而非类型系统保证）。
private final class PipeBuffers: @unchecked Sendable {
    private let lock = NSLock()
    /// stdout 残行（PROGRESS 行可能被管道切成两半）
    private var stdoutResidual = ""
    /// stderr 尾部（失败时给人看）
    private var stderrTail = ""

    /// 追加 stderr，只保留尾部 4KB（异常时可能刷屏，不能无界增长）
    func appendStderr(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        stderrTail.append(text)
        if stderrTail.count > 4096 { stderrTail = String(stderrTail.suffix(4096)) }
    }

    /// 直接设置 stderr（启动失败时用）
    func setStderr(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        stderrTail = text
    }

    /// 取 stderr 当前内容（进程退出时读一次）
    var stderrSnapshot: String {
        lock.lock(); defer { lock.unlock() }
        return stderrTail
    }

    /// 喂入 stdout 文本，返回本次解析出的完整进度行 `(阶段, 0…1)`
    func consumeStdout(_ chunk: Data) -> [(stage: String, pct: Double)] {
        guard let text = String(data: chunk, encoding: .utf8) else { return [] }
        lock.lock(); defer { lock.unlock() }
        stdoutResidual.append(text)
        // 残留超过 8KB 仍无换行说明协议异常，丢弃避免无界增长
        if stdoutResidual.count > 8192 { stdoutResidual = ""; return [] }
        var parsed: [(stage: String, pct: Double)] = []
        while let nl = stdoutResidual.firstIndex(of: "\n") {
            let line = String(stdoutResidual[stdoutResidual.startIndex..<nl])
            stdoutResidual = String(stdoutResidual[stdoutResidual.index(after: nl)...])
            let parts = line.components(separatedBy: "|")
            guard parts.count == 3, parts[0] == "PROGRESS",
                  let pct = Double(parts[2]) else { continue }
            parsed.append((parts[1], pct))
        }
        return parsed
    }

    /// 新一轮标注开始前清空，避免上一轮的残行/错误信息串到本轮
    func reset() {
        lock.lock(); defer { lock.unlock() }
        stdoutResidual = ""
        stderrTail = ""
    }
}

@MainActor
final class LeanAnnotateRunner {

    private var process: Process?
    /// 停滞看门狗：子进程超过 `stallTimeout` 没有任何进度就强杀。
    ///
    /// 【为什么是"停滞"而不是"总时长"】标注耗时随帧数线性增长（10 分钟素材约 9000 帧），
    ///   按总时长设上限要么误杀慢机器，要么宽到形同没有。而"还能不能吐 PROGRESS 行"
    ///   是**与机器快慢无关**的活性信号：只要还在推进就不该杀。
    /// 【为什么必须有】`terminationHandler` 只在进程**退出**时触发。若模型加载卡住、
    ///   或某帧 OCR 永久阻塞，进程既不退出也不报错 —— 于是 `isRunning` 恒 true、
    ///   进度条永远停在某个百分比、待标注队列被 `pump` 的门禁永久堵死。
    ///   屏外表现是"界面像死机但没有崩溃"，比直接报错更难排查。
    private var watchdog: DispatchWorkItem?
    /// 判定停滞的阈值（秒）。默认 120；自检会调小以在短时间内验证强杀路径。
    var stallTimeout: TimeInterval = 120

    // MARK: 自检注入点（生产路径恒为 nil，行为与不注入时逐字等价）
    //
    // 【为什么需要】看门狗的价值全在"进程卡死不退出时能不能杀掉"，而这正是
    //   正常标注**不会发生**的情形 —— 没有注入点就只能靠推理，无法实测。
    //   与 LeanRecordEngine.clipsRootOverride 同款思路：只加一个可覆盖入口，
    //   不改任何生产逻辑分支。
    /// 覆盖被拉起的可执行文件（自检用 `/bin/sleep` 造一个"永不结束"的子进程）
    var executableOverride: URL?
    /// 覆盖传给子进程的参数（自检用 `["300"]`）
    var argumentsOverride: [String]?
    /// 管道文本缓冲（stdout 残行 / stderr 尾部）。
    ///
    /// 【为什么放进自带锁的盒子，而不是本类的普通属性】`readabilityHandler` 由系统
    ///   在**后台队列**回调，而本类是 @MainActor：直接读写 `stdoutResidual` /
    ///   `stderrTail` 就是跨 actor 改状态（Swift 6 语言模式下会升级为错误）。
    ///   把"只被后台碰的数据"收进一个 `@unchecked Sendable` 的盒子，盒内自带
    ///   NSLock —— 这正是 `@unchecked` 的正当用法：线程安全由内部锁保证。
    private let pipeBuffers = PipeBuffers()

    /// (阶段名, 0…1)
    var onProgress: ((String, Double) -> Void)?
    /// (退出码, stderr 尾部)；退出码 0 = 通过/警告，2 = 输入错误，3 = 质量不合格
    var onFinish: ((Int32, String) -> Void)?

    var isRunning: Bool { process?.isRunning == true }

    /// 最近一次**启动失败**的原因（仅 `start()` 返回 false 时有效）。
    /// 与 `onFinish` 报的退出码失败是两回事：那个是子进程跑完但质检不合格，
    /// 这个是连进程都没起来（可执行文件无效 / run 抛错）。UI 需要区分这两种。
    private(set) var lastError: String?

    /// 是否因**停滞被强杀**（区别于子进程自己跑完但质检不合格）。
    /// UI 靠它给出"卡住了"而不是"数据不合格"的提示 —— 两者的处理动作完全不同。
    private(set) var didStallOut = false

    /// 布防 / 重置停滞看门狗。每收到一条 PROGRESS 行就重置一次。
    ///
    /// 【为什么重置而不是只布一次】"还能不能吐进度"是与机器快慢无关的活性信号：
    ///   慢机器上标注 9000 帧本身就久，只要还在推进就不该杀。
    private func armStallWatchdog() {
        watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            // 本闭包由 main queue 执行；@MainActor 类需要显式声明隔离。
            MainActor.assumeIsolated { self?.watchdogFired() }
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + stallTimeout, execute: item)
    }

    /// 看门狗到期：仍在运行就判为停滞并强杀。
    private func watchdogFired() {
        guard let p = process, p.isRunning else { return }
        didStallOut = true
        lastError = "标注子进程停滞超过 \(Int(stallTimeout)) 秒，已强制终止"
        print("[lean] ⚠️ \(lastError ?? "")")
        p.terminate()
        // SIGTERM 可能被子进程忽略（或它卡在内核 IO 里）：5s 后仍在就 SIGKILL 兜底。
        // 不兜底的话"强杀"本身也可能失效，看门狗就只是把一个 hang 换成了另一个 hang。
        //
        // 【为什么必须比对进程身份而不是只看 isRunning】这 5 秒里本轮可能已结束、
        //   下一轮标注可能已拉起新进程。此时单看 isRunning 会命中新进程，而 pid
        //   变量仍指向旧进程 —— pid 会被系统复用，kill 就打到无关进程上了。
        //   故连同 pid 一起比对，两者都对才认为是同一个卡死进程。
        let pid = p.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let cur = self.process, cur.isRunning,
                      cur.processIdentifier == pid else { return }
                kill(pid, SIGKILL)
                print("[lean] ⚠️ SIGTERM 未生效，已 SIGKILL 标注子进程 pid=\(pid)")
            }
        }
    }

    /// 拉起标注子进程。
    /// - Returns: false 表示无法启动（可执行文件无效或 run 抛错），调用方应显示错误
    func start(clipPath: String) -> Bool {
        lastError = nil
        didStallOut = false
        // 清空上一轮的管道残留：否则上一段的 stderr（比如"速度覆盖率 0%"）
        // 会挂在下一段的失败信息里，让人误判这段数据的问题。
        pipeBuffers.reset()
        guard !isRunning else {
            lastError = "已有标注进程在跑"
            return false
        }
        // 与 EngineClient 同款：用最开始的参数 0 定位自身（自检可覆盖）
        let exeURL = executableOverride ?? URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: exeURL.path) else {
            lastError = "可执行文件路径无效: \(exeURL.path)"
            return false
        }

        let p = Process()
        p.executableURL = exeURL
        p.arguments = argumentsOverride ?? ["--lean-annotate", clipPath]

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // 读干 stdout。`pipeBuffers` 自带锁，后台回调只碰盒子、不碰本类状态；
        // 解析出的进度行再回主线程刷新 UI（本方法已 @MainActor，闭包内直接调）。
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty, let self else { return }
            let updates = self.pipeBuffers.consumeStdout(chunk)
            guard !updates.isEmpty else { return }
            DispatchQueue.main.async {
                // 有进度 = 子进程还活着且在推进 → 重置停滞计时。
                self.armStallWatchdog()
                for u in updates { self.onProgress?(u.stage, u.pct) }
            }
        }
        // 读干 stderr：不读的话管道缓冲写满会让子进程**永久阻塞**在写 stderr 上，
        // 表现为"标注永远不结束"。
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty, let self else { return }
            guard let text = String(data: chunk, encoding: .utf8) else { return }
            self.pipeBuffers.appendStderr(text)
        }

        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            guard let self else { return }
            let tail = self.pipeBuffers.stderrSnapshot
            DispatchQueue.main.async {
                // 进程已退出：拆掉看门狗，否则它会对着一个已结束的进程空跑
                // （并可能在下一次 start() 后误杀新进程）。
                self.watchdog?.cancel()
                self.watchdog = nil
                self.process = nil
                self.onFinish?(code, tail)
            }
        }

        do {
            try p.run()
            process = p
            // 布防：进程起来就开始计时；此后每收到一条 PROGRESS 行都会重置。
            armStallWatchdog()
            return true
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            pipeBuffers.setStderr(error.localizedDescription)
            lastError = "拉起标注子进程失败: \(error.localizedDescription)"
            return false
        }
    }

    /// 应用退出时同步收尾：杀掉仍在跑的标注子进程。
    ///
    /// 【为什么必须做】子进程是**独立进程**，App 退出不会带走它。它若还在跑，会继续
    ///   往同一份 controls.csv 回填；用户重开 App 再标同一段，就有两个进程同时改一个
    ///   文件。孤儿进程还要等自己跑完才消失，期间 CPU 一直被占。
    ///
    /// 【为什么带等待而不是直接 SIGKILL】子进程可能正处在「写 tmp → 原子替换」中间，
    ///   硬杀会留下 controls.csv.tmp。先 SIGTERM 给一点时间让它走到安全点，超时才
    ///   SIGKILL —— 等待是有界的（默认 1.5s），不会把 App 退出卡住。
    func shutdown(timeout: TimeInterval = 1.5) {
        watchdog?.cancel()
        watchdog = nil
        guard let p = process, p.isRunning else {
            process = nil
            return
        }
        let pid = p.processIdentifier
        p.terminate()
        let deadline = Date(timeIntervalSinceNow: timeout)
        while p.isRunning && Date() < deadline {
            usleep(50_000)  // 50ms
        }
        if p.isRunning {
            kill(pid, SIGKILL)
            print("[lean] ⚠️ 退出时标注子进程未响应 SIGTERM，已 SIGKILL pid=\(pid)")
        }
        process = nil
        print("[lean] 退出前已收尾标注子进程 pid=\(pid)")
    }
}
