// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  LeanRecordSelfTest.swift — 精简录制器端到端自检（--lean-selftest）
//
//  【为什么必须建这个】
//    引擎能编译 ≠ 写出的数据能被训练端用。历史上本项目已多次出现
//    「登记了自检却从未真跑」→ 假绿。本文件真实跑一遍完整链路：
//    造帧 → appendFrame → 编码 → 落盘 → 写 CSV/meta，然后逐条断言
//    产物满足 `dataset_v3` 的硬约束。
//
//  【断言的核心不变量】
//    ① CSV 第 i 个数据行的 frame 列 == i，且 frames/{i:06d}.jpg 存在
//       —— dataset_v3 用行号拼文件名却校验 frame 列，错位即整体标签错配。
//    ② 写盘失败**不占用帧号、不写 CSV 行** —— 否则 frames/ 留洞而 CSV 连续，
//       整份数据静默错位（这是本录制器最容易引入的致命缺陷）。
//    ③ 表头 19 列，且每行字段数 == 19。
//    ④ 缺失定位写空串而非 0（0 会被当成"车在世界原点"）。
//    ⑤ meta.json 的 width/height 是真实值（不是 0×0）。
//    ⑥ 15Hz 节奏下 t_sec 反推 fps 在 dataset_v3 的 ±15% 容差内。
//
//  【为什么第二段要 chmod 0555】
//    "写失败"在正常环境几乎不会发生，不人为制造就测不到不变量 ②。
//    把 frames/ 设为只读可稳定复现写入失败，且不改动业务代码。
// ============================================================================

import AppKit
import CoreVideo
import Foundation

enum LeanRecordSelfTest {

    static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if !condition { failures += 1 }
            print("  \(condition ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        }

        print("═══ 精简录制器端到端自检 ═══")

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lean_selftest_\(Int(Date().timeIntervalSince1970))")
        // 刻意**不做 defer 清理**：产物要留给外部 Python 端到端校验
        // （拿真实产物跑 dataset_v3，证明训练端能加载，而不只是 Swift 自己说对）。
        // 目录名带时间戳、位于 NSTemporaryDirectory()，由系统回收；
        // 也因此绝不删除任何非本次创建的目录。
        print("  LEAN_SELFTEST_ROOT=\(root.path)")

        // ── 第一段：正常录制 30 帧 @15Hz ──
        print("  ── 第一段：30 帧 / 15Hz 正常录制 ──")
        guard let buffer = makeTestPixelBuffer(width: 1280, height: 832) else {
            print("  ✗ 无法构造测试帧缓冲（CVPixelBufferCreate 失败）")
            return failures + 1
        }

        var keyCursor = 0
        let keySequence: [RawKeySample] = [
            RawKeySample(),
            sampleKey(w: 1),
            sampleKey(w: 1, a: 1),
            sampleKey(shift: 1, space: 1),                 // 超级刹车
            sampleKey(s: 1, shift: 1, space: 1),           // 极致刹车（S 同时是防翻车稳定键）
        ]

        var poseCursor = 0
        let engine = LeanRecordEngine()
        engine.clipsRootOverride = root.appendingPathComponent("normal")
        engine.keyProvider = {
            defer { keyCursor += 1 }
            return keySequence[keyCursor % keySequence.count]
        }
        engine.poseProvider = {
            defer { poseCursor += 1 }
            // 第 5..9 帧故意不给定位，验证"缺失写空串"
            if (5...9).contains(poseCursor % 30) { return (nil, nil) }
            return ((100.0 + Double(poseCursor), 200.0, 3.5, 1.25, 45.0),
                    (0.3, -0.1, 9.8))
        }

        check("start() 成功", engine.start(), engine.lastError ?? "")

        let frameCount = 30
        let frameInterval: useconds_t = 66_667     // 1/15 s
        for _ in 0..<frameCount {
            engine.appendFrame(pixelBuffer: buffer)
            usleep(frameInterval)
        }
        engine.stop()

        let normalClips = clips(in: root.appendingPathComponent("normal"))
        check("生成 1 个 clip 目录", normalClips.count == 1, "实际 \(normalClips.count)")
        guard let clip = normalClips.first else { return failures + 1 }

        // ── 文件集 ──
        print("  ── 文件集 ──")
        check("controls.csv 存在", FileManager.default.fileExists(
            atPath: clip.appendingPathComponent("controls.csv").path))
        check("view.txt 存在", FileManager.default.fileExists(
            atPath: clip.appendingPathComponent("view.txt").path))
        let viewText = (try? String(contentsOf: clip.appendingPathComponent("view.txt"),
                                    encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        check("view.txt 内容为 TPV", viewText == "TPV", viewText ?? "nil")
        check("meta.json 存在", FileManager.default.fileExists(
            atPath: clip.appendingPathComponent("meta.json").path))

        let framesDir = clip.appendingPathComponent("frames")
        let jpgs = (try? FileManager.default.contentsOfDirectory(atPath: framesDir.path))?
            .filter { $0.hasSuffix(".jpg") }.sorted() ?? []
        check("JPEG 数量 == \(frameCount)", jpgs.count == frameCount, "实际 \(jpgs.count)")
        check("文件名从 000000 连续", jpgs.first == "000000.jpg" && jpgs.last == String(format: "%06d.jpg", frameCount - 1),
              "\(jpgs.first ?? "nil") … \(jpgs.last ?? "nil")")

        // ── CSV 结构 ──
        print("  ── CSV 结构 ──")
        let csvURL = clip.appendingPathComponent("controls.csv")
        let csvText = (try? String(contentsOf: csvURL, encoding: .utf8)) ?? ""
        let allLines = csvText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        check("CSV 有内容", !allLines.isEmpty)
        let header = allLines.first?.split(separator: ",", omittingEmptySubsequences: false).map(String.init) ?? []
        check("表头 19 列", header.count == 19, "实际 \(header.count)")
        let expectedHeader = ["t_sec", "frame", "x", "y", "z", "pitch", "heading",
                              "ax", "ay", "az", "speed_kmh",
                              "w", "a", "s", "d", "shift", "space",
                              "super_brake", "ultimate_brake"]
        check("表头列名与顺序正确", header == expectedHeader,
              header.count == 19 ? "" : "列数不符")

        let rows = allLines.dropFirst().map {
            $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }
        check("数据行数 == \(frameCount)", rows.count == frameCount, "实际 \(rows.count)")
        check("每行 19 个字段", rows.allSatisfy { $0.count == 19 },
              "异常行数 \(rows.filter { $0.count != 19 }.count)")

        // ── 不变量 ①：frame 列与行号、文件名三者一致 ──
        print("  ── 不变量①：CSV 行号 ⟷ frame 列 ⟷ 文件名 ──")
        var frameMismatch: [String] = []
        for (i, row) in rows.enumerated() where row.count == 19 {
            if row[1] != String(i) { frameMismatch.append("行\(i):frame=\(row[1])") }
        }
        check("frame 列 == 行号（全部 \(frameCount) 行）", frameMismatch.isEmpty,
              frameMismatch.prefix(3).joined(separator: " "))
        let fileMismatch = rows.enumerated().compactMap { i, _ -> String? in
            FileManager.default.fileExists(atPath: framesDir
                .appendingPathComponent(String(format: "%06d.jpg", i)).path) ? nil : "缺 \(i)"
        }
        check("每行都有对应 JPEG", fileMismatch.isEmpty, fileMismatch.prefix(3).joined(separator: " "))

        // ── 不变量 ④：缺失定位写空串 ──
        print("  ── 不变量④：缺失定位写空串（不是 0）──")
        let missingPoseRows = rows.filter { ($0.count == 19) && $0[2].isEmpty }
        check("存在缺定位行（第5..9帧）", missingPoseRows.count == 5, "实际 \(missingPoseRows.count)")
        check("缺定位行的 x/y/z 全为空串",
              missingPoseRows.allSatisfy { $0[2].isEmpty && $0[3].isEmpty && $0[4].isEmpty })
        let presentPoseRows = rows.filter { ($0.count == 19) && !$0[2].isEmpty }
        check("有定位行的 x 非空且非 0", presentPoseRows.allSatisfy { $0[2] != "0.000" })

        // ── 按键标签 ──
        print("  ── 按键标签 ──")
        // keySequence 以 5 为周期：第 3 帧 = 超级刹车，第 4 帧 = 极致刹车
        //
        // ⚠️ 一律按**列名**取值，不硬编码列下标：
        //    本自检第一版就是写死 rows[4][14] 当 s 列，而 s 实际在第 13 列、
        //    第 14 列是 d —— 于是引擎完全正确却报了假失败。列名取值对列序免疫。
        func col(_ row: [String], _ name: String) -> String? {
            guard let i = header.firstIndex(of: name), i < row.count else { return nil }
            return row[i]
        }
        if rows.count > 4, rows[3].count == 19, rows[4].count == 19 {
            check("第3帧 super_brake=1", col(rows[3], "super_brake") == "1",
                  col(rows[3], "super_brake") ?? "nil")
            check("第3帧 ultimate_brake=0", col(rows[3], "ultimate_brake") == "0",
                  col(rows[3], "ultimate_brake") ?? "nil")
            check("第4帧 super_brake=1", col(rows[4], "super_brake") == "1",
                  col(rows[4], "super_brake") ?? "nil")
            check("第4帧 ultimate_brake=1", col(rows[4], "ultimate_brake") == "1",
                  col(rows[4], "ultimate_brake") ?? "nil")
            check("第4帧 s=1（防翻车稳定键）", col(rows[4], "s") == "1",
                  col(rows[4], "s") ?? "nil")
            let atomicKeys = ["w", "a", "s", "d", "shift", "space",
                              "super_brake", "ultimate_brake"]
            check("第0帧全部按键为 0",
                  atomicKeys.allSatisfy { col(rows[0], $0) == "0" })
        }

        // ── 不变量 ⑥：fps ──
        print("  ── 不变量⑥：15Hz ──")
        let tSecs = rows.compactMap { $0.count == 19 ? Double($0[0]) : nil }
        let deltas = zip(tSecs, tSecs.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
        if let median = deltas.isEmpty ? nil : deltas[deltas.count / 2] {
            let actualFPS = 1.0 / median
            let deviation = abs(actualFPS - 15.0) / 15.0
            check("反推 fps 在 ±15% 内", deviation <= 0.15,
                  String(format: "%.2ffps（偏差 %.1f%%）", actualFPS, deviation * 100))
        } else {
            check("反推 fps 在 ±15% 内", false, "无有效时间差")
        }

        // ── JPEG 可解码且尺寸正确 ──
        print("  ── JPEG 有效性 ──")
        let firstJPG = framesDir.appendingPathComponent("000000.jpg")
        let imageData = try? Data(contentsOf: firstJPG)
        check("JPEG 魔数 FF D8", imageData?.prefix(2).map { $0 } == [0xFF, 0xD8],
              imageData.map { String(format: "%02X %02X", $0[0], $0[1]) } ?? "nil")
        if let imageData, let rep = NSBitmapImageRep(data: imageData) {
            // 用 pixelsWide/pixelsHigh 而不是 NSImage.size：
            // NSImage.size 是**点**尺寸，会随 DPI（72 以外的元数据）缩放，
            // 用它断言像素数可能在 DPI 非 72 时假通过/假失败。
            check("JPEG 可解码", true)
            check("解码像素尺寸 1280×832", rep.pixelsWide == 1280 && rep.pixelsHigh == 832,
                  "\(rep.pixelsWide)×\(rep.pixelsHigh)")
        } else {
            check("JPEG 可解码", false)
        }

        // ── 不变量 ⑤：meta.json 真实宽高 ──
        print("  ── 不变量⑤：meta.json ──")
        let metaURL = clip.appendingPathComponent("meta.json")
        if let metaData = try? Data(contentsOf: metaURL),
           let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
            check("meta.width == 1280", (meta["width"] as? Int) == 1280, "\(meta["width"] ?? "nil")")
            check("meta.height == 832", (meta["height"] as? Int) == 832, "\(meta["height"] ?? "nil")")
            check("meta.frames == \(frameCount)", (meta["total_frames"] as? Int) == frameCount,
                  "\(meta["total_frames"] ?? "nil")")
            check("meta.fps == 15", (meta["fps"] as? Double) == 15.0, "\(meta["fps"] ?? "nil")")
            check("meta.heading_semantics == camera",
                  (meta["heading_semantics"] as? String) == "camera",
                  "\(meta["heading_semantics"] ?? "nil")")
            check("meta.pcap_ok == true（本段有定位）",
                  (meta["pcap_ok"] as? Bool) == true, "\(meta["pcap_ok"] ?? "nil")")
        } else {
            check("meta.json 可解析", false)
        }

        // ── 第二段：制造写盘失败，验证不变量 ② ──
        print("  ── 第二段：写盘失败不占用帧号 ──")
        let failEngine = LeanRecordEngine()
        failEngine.clipsRootOverride = root.appendingPathComponent("failure")
        failEngine.keyProvider = { RawKeySample() }
        failEngine.poseProvider = { (nil, nil) }
        check("第二段 start() 成功", failEngine.start(), failEngine.lastError ?? "")

        let failClips = clips(in: root.appendingPathComponent("failure"))
        guard let failClip = failClips.first else {
            check("第二段 clip 目录存在", false)
            return failures + 1
        }
        let failFramesDir = failClip.appendingPathComponent("frames")
        // 只读：写 .atomic 临时文件会失败，稳定复现"写盘失败"。
        // 用 chmod 而不是注入错误：不改业务代码，失败来自真实 IO 路径。
        try? FileManager.default.setAttributes([.posixPermissions: 0o555],
                                               ofItemAtPath: failFramesDir.path)

        failEngine.appendFrame(pixelBuffer: buffer)
        // stop() 内部的 writeQueue.sync 是**确定性屏障**：它必然排在已入队帧之后执行。
        // 不能用固定 sleep 猜时序 —— 若写队列尚未跑到而权限已恢复，这一帧会成功写入，
        // 于是"失败"根本没发生，断言就成了假失败（这类自检比没有自检更危险）。
        failEngine.stop()

        let failedCSV = (try? String(contentsOf: failClip.appendingPathComponent("controls.csv"),
                                     encoding: .utf8)) ?? ""
        let failedDataRows = failedCSV.split(separator: "\n", omittingEmptySubsequences: true)
            .dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false) }
        check("写入失败的帧不产生 CSV 行", failedDataRows.isEmpty, "实际 \(failedDataRows.count) 行")
        let failedJPEGs = ((try? FileManager.default.contentsOfDirectory(atPath: failFramesDir.path))?
            .filter { $0.hasSuffix(".jpg") }) ?? []
        check("写入失败的帧不产生 JPEG", failedJPEGs.isEmpty, failedJPEGs.joined(separator: ","))
        check("失败计数记为 1", failEngine.writeFailureCount == 1,
              "实际 \(failEngine.writeFailureCount)")
        check("总帧数为 0（失败帧不计入）", failEngine.frameCount == 0,
              "实际 \(failEngine.frameCount)")

        // 恢复可写，开第二段会话验证：失败没留下任何残留（无 000000.jpg、无半写临时文件），
        // 新会话从帧号 0 重新开始且连续无空洞。这是"写失败不占用帧号"的可观测后果。
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: failFramesDir.path)
        check("恢复后再次 start() 成功", failEngine.start(), failEngine.lastError ?? "")
        // 必须按 15Hz 真实节奏喂帧，否则 t_sec 间隔会被压到微秒级：
        // 实测不等待时 dt=10µs → 反推 100000fps，`dataset_v3` 直接 raise
        // （"实际帧率约 100000.0fps，与 V3 假设的 15fps 不符"）。
        // 这不是引擎缺陷 —— 生产环境帧来自 15Hz 抓屏，本自检必须复现同样的节奏。
        failEngine.appendFrame(pixelBuffer: buffer)
        usleep(66_667)
        failEngine.appendFrame(pixelBuffer: buffer)
        usleep(66_667)
        failEngine.stop()

        let recoveredClips = clips(in: root.appendingPathComponent("failure"))
        check("失败段与恢复段各 1 个 clip", recoveredClips.count == 2, "实际 \(recoveredClips.count)")
        if let recovered = recoveredClips.last {
            let recoveredFramesDir = recovered.appendingPathComponent("frames")
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: recoveredFramesDir.path))?
                .filter { $0.hasSuffix(".jpg") }.sorted()) ?? []
            check("恢复段 JPEG 连续 000000/000001",
                  names == ["000000.jpg", "000001.jpg"], names.joined(separator: ","))
            let recoveredCSV = (try? String(contentsOf: recovered.appendingPathComponent("controls.csv"),
                                            encoding: .utf8)) ?? ""
            let recoveredRows = recoveredCSV.split(separator: "\n", omittingEmptySubsequences: true)
                .dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false) }
            check("恢复段 2 行且 frame 列为 0,1",
                  recoveredRows.count == 2
                    && recoveredRows[0].count > 1 && recoveredRows[0][1] == "0"
                    && recoveredRows[1].count > 1 && recoveredRows[1][1] == "1",
                  "行数 \(recoveredRows.count)")
        } else {
            check("恢复段 clip 存在", false)
        }

        // ── 第三段：15fps 限流（不变量 ⑦）──
        // 为什么需要这一段：限流是**唯一**会把正常帧丢掉的地方，丢错了会让整段
        // 数据掉出 dataset_v3 的 15±15% 容差（屏外表现是"录制正常但训练端拒载"），
        // 而这种缺陷在人工试用时完全看不出来 —— 必须由断言守住。
        //
        // 为什么不靠"按 15Hz 喂 30 帧再看 fps"来测：那样的结论取决于机器抖动，
        // 机器慢一点就假失败。这里用**确定性**判据：
        //   · 连灌 10 帧（间隔 ~微秒级，远小于 minGap=60ms）→ 只应接受第 1 帧
        //   · 再 usleep(70ms)（> 60ms 判据）→ 应接受第 2 帧
        // 两个方向都断言：该挡的挡住了，该放的也放行了（防止限流写死成"全挡"）。
        print("  ── 第三段：15fps 限流 ──")
        let throttleEngine = LeanRecordEngine()
        throttleEngine.clipsRootOverride = root.appendingPathComponent("throttle")
        throttleEngine.keyProvider = { RawKeySample() }
        throttleEngine.poseProvider = { (nil, nil) }
        check("第三段 start() 成功", throttleEngine.start(), throttleEngine.lastError ?? "")
        for _ in 0..<10 { throttleEngine.appendFrame(pixelBuffer: buffer) }
        usleep(70_000)                                    // 70ms > minGap 60ms
        throttleEngine.appendFrame(pixelBuffer: buffer)   // 该被放行
        throttleEngine.stop()                             // writeQueue.sync 确定性屏障

        let throttleClips = clips(in: root.appendingPathComponent("throttle"))
        if let throttleClip = throttleClips.first {
            let throttleRows = ((try? String(contentsOf: throttleClip
                .appendingPathComponent("controls.csv"), encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
                .map { $0.split(separator: ",", omittingEmptySubsequences: false) }
            check("连灌 10 帧 + 70ms 后 1 帧 → 共 2 行", throttleRows.count == 2,
                  "实际 \(throttleRows.count) 行")
            check("限流后 frame 列为 0,1",
                  throttleRows.count == 2
                    && throttleRows[0].count > 1 && throttleRows[0][1] == "0"
                    && throttleRows[1].count > 1 && throttleRows[1][1] == "1",
                  throttleRows.compactMap { $0.count > 1 ? String($0[1]) : nil }
                      .joined(separator: ","))
            let throttleJPGs = ((try? FileManager.default.contentsOfDirectory(
                atPath: throttleClip.appendingPathComponent("frames").path))?
                .filter { $0.hasSuffix(".jpg") }.sorted()) ?? []
            check("限流后 JPEG 为 000000/000001",
                  throttleJPGs == ["000000.jpg", "000001.jpg"],
                  throttleJPGs.joined(separator: ","))
        } else {
            check("第三段 clip 存在", false)
        }

        // ── 第四段：分段回调 onSegmentClosed（不变量 ⑧）──
        // 为什么需要这一段：10 分钟自动分段会把一次长录切成多段，若只有"最后一段"
        // 被标注，前面的中间段 speed_kmh 会永久为空 —— 训练端 speed_valid=0，
        // 速度特征整路没数据，而录制日志一切正常、屏外完全看不出来。
        // 判据：缩短 maxSegmentSeconds 触发真实轮转，断言回调**每段都触发一次**。
        //
        // ⚠️ 轮转块在主线程 `DispatchQueue.main.async` 里执行，而本自检也在主线程
        //    同步跑 —— 不抽主运行循环的话那段永远不会执行（测试会假失败）。
        print("  ── 第四段：分段回调（每段都要被标注）──")
        let rotateEngine = LeanRecordEngine()
        rotateEngine.clipsRootOverride = root.appendingPathComponent("rotation")
        rotateEngine.keyProvider = { RawKeySample() }
        rotateEngine.poseProvider = { (nil, nil) }
        rotateEngine.maxSegmentSeconds = 0.05          // 70ms/帧 → 第 2 帧即触发轮转
        var closedPaths: [String] = []
        rotateEngine.onSegmentClosed = { closedPaths.append($0) }
        check("第四段 start() 成功", rotateEngine.start(), rotateEngine.lastError ?? "")

        rotateEngine.appendFrame(pixelBuffer: buffer)  // 第 1 帧：不触发
        usleep(70_000)
        rotateEngine.appendFrame(pixelBuffer: buffer)  // 第 2 帧：触发轮转 → main.async

        // 抽主运行循环，让轮转块里的 stop()+start() 真正执行（有界等待，不靠盲睡）
        let rotateDeadline = Date().addingTimeInterval(2.0)
        while closedPaths.isEmpty && Date() < rotateDeadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        check("轮转触发 onSegmentClosed", closedPaths.count == 1, "实际 \(closedPaths.count) 次")

        // ⚠️ 必须把阈值调回去：新段沿用 0.05s 的话，下面 sleep 70ms 后再喂帧会
        //    立刻再次触发轮转（elapsed 70ms ≥ 50ms），断言会变成 3 次/3 段而假失败。
        rotateEngine.maxSegmentSeconds = 600
        usleep(70_000)                                // 越过 minGap，让新段接受下一帧
        rotateEngine.appendFrame(pixelBuffer: buffer)  // 新段 1 帧
        rotateEngine.stop()                           // 收尾 → 再触发一次

        check("停录也触发 onSegmentClosed（共 2 次）", closedPaths.count == 2,
              "实际 \(closedPaths.count) 次")
        let rotateClips = clips(in: root.appendingPathComponent("rotation"))
        check("轮转产出 2 个 clip 目录", rotateClips.count == 2, "实际 \(rotateClips.count)")
        // 每段都必须是"可直接标注的完整产物"：有 controls.csv 且 frames/ 可读
        let usable = closedPaths.allSatisfy { p in
            let u = URL(fileURLWithPath: p)
            return FileManager.default.fileExists(atPath: u.appendingPathComponent("controls.csv").path)
                && FileManager.default.fileExists(atPath: u.appendingPathComponent("meta.json").path)
        }
        check("回调路径都是完整产物（含 controls.csv + meta.json）", usable,
              closedPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ","))
        check("两段回调路径互不相同", Set(closedPaths).count == closedPaths.count,
              closedPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ","))

        print("")
        print(failures == 0
              ? "✅ 精简录制器自检全部通过"
              : "❌ 精简录制器自检失败 \(failures) 项")
        return failures
    }

    // MARK: - 辅助

    private static func clips(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { $0.hasPrefix("clip_") }
            .sorted()
            .map { root.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("controls.csv").path) }
    }

    private static func sampleKey(w: Int = 0, a: Int = 0, s: Int = 0, d: Int = 0,
                                  shift: Int = 0, space: Int = 0) -> RawKeySample {
        var k = RawKeySample()
        k.w = w; k.a = a; k.s = s; k.d = d; k.shift = shift; k.space = space
        return k
    }

    /// 造一张 32BGRA 测试帧（与 capture 通道同格式，走同一条编码路径）。
    private static func makeTestPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return buf }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buf)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pixels[offset + 0] = UInt8(truncatingIfNeeded: x &* 3)
                pixels[offset + 1] = UInt8(truncatingIfNeeded: y &* 5)
                pixels[offset + 2] = UInt8(truncatingIfNeeded: (x ^ y) &* 7)
                pixels[offset + 3] = 255
            }
        }
        return buf
    }
}
