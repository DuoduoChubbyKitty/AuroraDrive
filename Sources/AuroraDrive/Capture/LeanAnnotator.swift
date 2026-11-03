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
@MainActor
final class LeanAnnotateRunner {

    private var process: Process?
    /// stdout 残行缓冲（PROGRESS 行可能被管道切成两半）
    private var stdoutResidual = ""
    /// stderr 累积（只保留尾部，用于失败时给人看）
    private var stderrTail = ""
    /// 管道回调在后台队列，收口到这一条串行队列，避免多线程同改缓冲
    private let ioQueue = DispatchQueue(label: "com.aurora.leanannotate.io")

    /// (阶段名, 0…1)
    var onProgress: ((String, Double) -> Void)?
    /// (退出码, stderr 尾部)；退出码 0 = 通过/警告，2 = 输入错误，3 = 质量不合格
    var onFinish: ((Int32, String) -> Void)?

    var isRunning: Bool { process?.isRunning == true }

    /// 最近一次**启动失败**的原因（仅 `start()` 返回 false 时有效）。
    /// 与 `onFinish` 报的退出码失败是两回事：那个是子进程跑完但质检不合格，
    /// 这个是连进程都没起来（可执行文件无效 / run 抛错）。UI 需要区分这两种。
    private(set) var lastError: String?

    /// 拉起标注子进程。
    /// - Returns: false 表示无法启动（可执行文件无效或 run 抛错），调用方应显示错误
    func start(clipPath: String) -> Bool {
        lastError = nil
        guard !isRunning else {
            lastError = "已有标注进程在跑"
            return false
        }
        // 与 EngineClient 同款：用最开始的参数 0 定位自身
        let exeURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: exeURL.path) else {
            lastError = "可执行文件路径无效: \(exeURL.path)"
            return false
        }

        let p = Process()
        p.executableURL = exeURL
        p.arguments = ["--lean-annotate", clipPath]

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { return }
            self?.ioQueue.async {
                guard let self else { return }
                self.consumeStdout(chunk)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { return }
            self?.ioQueue.async {
                guard let self else { return }
                guard let text = String(data: chunk, encoding: .utf8) else { return }
                self.stderrTail.append(text)
                // 只留尾部 4KB：正常情况是汇总信息，异常情况（崩溃刷屏）不能无限增长
                if self.stderrTail.count > 4096 {
                    self.stderrTail = String(self.stderrTail.suffix(4096))
                }
            }
        }

        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            self?.ioQueue.async {
                guard let self else { return }
                let tail = self.stderrTail
                DispatchQueue.main.async {
                    self.process = nil
                    self.onFinish?(code, tail)
                }
            }
        }

        do {
            try p.run()
            process = p
            return true
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            stderrTail = error.localizedDescription
            lastError = "拉起标注子进程失败: \(error.localizedDescription)"
            return false
        }
    }

    /// 解析 `PROGRESS|阶段|0.1234` 行（在 ioQueue 上调用）
    private func consumeStdout(_ chunk: Data) {
        guard let text = String(data: chunk, encoding: .utf8) else { return }
        stdoutResidual.append(text)
        // 残留超过 8KB 仍无换行说明协议异常，丢弃避免无界增长
        if stdoutResidual.count > 8192 { stdoutResidual = "" ; return }
        while let nl = stdoutResidual.firstIndex(of: "\n") {
            let line = String(stdoutResidual[stdoutResidual.startIndex..<nl])
            stdoutResidual = String(stdoutResidual[stdoutResidual.index(after: nl)...])
            let parts = line.components(separatedBy: "|")
            guard parts.count == 3, parts[0] == "PROGRESS",
                  let pct = Double(parts[2]) else { continue }
            let stage = parts[1]
            DispatchQueue.main.async { [weak self] in
                self?.onProgress?(stage, pct)
            }
        }
    }
}
