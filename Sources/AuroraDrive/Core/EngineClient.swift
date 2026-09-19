// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  EngineClient.swift — UI 侧引擎客户端（步骤3）
//
//  职责：
//   1) 启动探测：engine.sock 已有健康引擎 → 直接连接；
//      没有 → spawn 自己（同二进制 + --engine，输出重定向到引擎日志）
//   2) 连接成功后进入「引擎模式」：UI 只做显示与命令转发
//   3) 每 tick poll()：从共享内存读最新帧（BGRA → CGImage）与检测结果
//   4) 心跳接收：更新引擎状态；心跳超时/进程重启检测
//
//  回退：任何一步失败 → isActive 保持 false → UI 完全走本地模式（原逻辑不动）
//  强制本地模式：环境变量 AURORA_UI_LOCAL=1
// ============================================================================

import Foundation
import Darwin
import CoreGraphics
import AppKit

/// UI 侧引擎客户端日志：同时写 stdout 与 ~/Library/Logs/AuroraEngineClient.log
/// （GUI 进程 stdout 常被缓冲，落盘才能在退出后复查）
func engineClientLog(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    let line = "[\(f.string(from: Date()))] [UI-CLIENT] \(msg)\n"
    FileHandle.standardOutput.write(line.data(using: .utf8) ?? Data())
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AuroraEngineClient.log").path
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8) ?? Data())
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: nil)
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8) ?? Data())
            fh.closeFile()
        }
    }
}

@MainActor
final class EngineClient {

    static let shared = EngineClient()

    /// 引擎 socket 协议版本。⚠️ 任何命令 / 心跳字段变更都必须 +1。
    ///
    /// 为什么需要：UI 与引擎是两个独立长驻进程。重编译后旧引擎可能还活着，
    /// 而 UI 启动时只要 socket 有人应答就直接连上（单例设计）。
    /// 于是「新 UI 对着旧引擎说话」——新命令被旧引擎丢进 `未知命令类型`，
    /// **静默失败**（按钮照常翻转，引擎毫无反应）。
    ///
    /// 1 = 原始（start/stop/bye/status/upscale/ping）
    /// 2 = 新增 record / reloadmodel / config + 心跳 recording/frames/proto
    nonisolated static let protocolVersion = 2

    // ── UI 读取的状态 ──
    private(set) var isActive = false          // 引擎模式已激活（连接成功）
    private(set) var isConnected = false       // 心跳正常
    private(set) var engineIsDriving = false
    private(set) var engineIsStreaming = false
    private(set) var engineFPS: Double = 0
    private(set) var engineDetections: [Detection] = []
    private(set) var lastHeartbeat = Date.distantPast
    private(set) var enginePID: Int32 = 0
    /// 引擎自报的协议版本（0 = 旧引擎，不发 proto 字段）
    private(set) var engineProtocol = 0
    /// 是否已经历过至少一次「连接激活 → 收到心跳」的完整周期。
    /// 只有它成立时才允许判定版本错配，避免启动瞬间误判。
    private(set) var sawHeartbeat = false

    // ── 内部 ──
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var lineBuffer = Data()
    private var shmBase: UnsafeMutableRawPointer?
    private var shmSize = 0
    private var frameCache: CGImage?
    private var lastFrameSeq: UInt64 = 0
    private var frameCountSinceConnect = 0

    // ── 引擎回传的驾驶状态（引擎模式下 UI 不跑推理，面板显示靠这些）──
    /// 降级档位（引擎是权威源）
    private(set) var engineMode: DriveMode = .e2e
    /// 有效车速（km/h）
    private(set) var engineSpeed: Double = 0
    /// 车速表 OCR 读数（km/h；-1 = 未读到）
    private(set) var engineSpeedKmh: Double = -1
    /// 驾驶置信度（0~1）
    private(set) var engineConfidence: Double = 0
    /// 引擎录制状态（引擎是权威源：帧在引擎进程里，UI 只负责显示与转发开关）
    private(set) var engineRecording = false
    /// 引擎已写盘的录制帧数
    private(set) var engineRecordFrames = 0

    /// UI 当前是否要「像素缓冲」形态的帧（开了插帧时为 true）——
    /// 由 UI 每 tick 设置；引擎侧也会收到同名开关命令来决定发全分辨率还是缩略帧。
    var wantPixelBuffer = false
    private var pendingPixelBuffer: CVPixelBuffer?
    private var cvPool: CVPixelBufferPool?
    private var cvPoolW = 0
    private var cvPoolH = 0
    private var connectTimer: DispatchSourceTimer?
    private var connectAttempts = 0

    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AuroraDrive/engine.sock").path
    }
    static var engineLogPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AuroraEngine.log").path
    }

    private let queue = DispatchQueue(label: "aurora.engine.client", qos: .userInteractive)

    /// 等待旧引擎退场的轮询定时器（relaunchStaleEngine 持有）
    private var relaunchPoll: DispatchSourceTimer?
    /// UI 侧「已发起重启陈旧引擎」标记，防止 30Hz tick 重复触发
    var engineRelaunching = false

    // MARK: - 启动探测 / spawn

    /// 由 AppDelegate 在 applicationDidFinishLaunching 调用（非阻塞）
    func startup() {
        if ProcessInfo.processInfo.environment["AURORA_UI_LOCAL"] == "1" {
            engineClientLog("AURORA_UI_LOCAL=1 → 本地模式")
            return
        }
        // 1) 已有引擎 → 直接连
        if tryConnect() {
            activate()
            return
        }
        // 2) 没有 → spawn 引擎，然后异步轮询连接（不阻塞 UI 启动）
        guard spawnEngine() else {
            engineClientLog("引擎 spawn 失败 → 回退本地模式")
            return
        }
        engineClientLog("已拉起引擎子进程，等待 socket…")
        connectAttempts = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connectAttempts += 1
                if self.tryConnect() {
                    self.activate()
                    self.connectTimer?.cancel()
                    self.connectTimer = nil
                } else if self.connectAttempts >= 20 {   // 6 秒仍未连上
                    engineClientLog("等待引擎超时 → 回退本地模式")
                    self.connectTimer?.cancel()
                    self.connectTimer = nil
                }
            }
        }
        timer.resume()
        connectTimer = timer
    }

    private func activate() {
        isActive = true
        isConnected = true
        lastHeartbeat = Date()
        attachShm()
        engineClientLog("✅ 引擎模式已激活（socket + 共享内存就绪）")
        // 重连后主动同步一次画面档位（UI 可能开着插帧）
        onActivated?()
    }

    /// 激活（含重连）后的回调：UI 用它把当前档位/状态同步给引擎
    var onActivated: (() -> Void)?

    /// 尝试连接引擎 socket
    private func tryConnect() -> Bool {
        guard socketFD < 0 else { return true }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(Self.socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd); return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                memcpy(dst, src.baseAddress!, src.count)
            }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return false
        }
        socketFD = fd
        lineBuffer.removeAll(keepingCapacity: true)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            self?.readSocket()
        }
        src.resume()
        readSource = src
        // 主动要一次状态
        sendCommand("status")
        return true
    }

    /// 是否已与「协议版本不匹配的旧引擎」建立过连接。
    ///
    /// ⚠️ 判定前提必须是 `sawHeartbeat`，不能写 `engineProtocol != 0`：
    /// **旧引擎压根不发 `proto` 字段**，它的心跳让 `engineProtocol` 永远停在 0。
    /// 若把 0 当「未知、不算错配」，守卫会恰好漏掉「新 UI × 旧引擎」这个
    /// 唯一需要它生效的场合（2026-09-12 实测踩坑）。
    var isEngineStale: Bool {
        sawHeartbeat && engineProtocol != Self.protocolVersion
    }

    /// 终止协议不匹配的旧引擎，并拉起同版本新引擎。
    ///
    /// ⚠️ 2026-09-12 踩坑记录（第一版写错，导致 UI 陷入无限重启）：
    ///   1. **`bye` 不会让引擎退出** —— 它只做 `pauseDriving()`，然后等 30 秒空闲才退。
    ///      所以这里**必须真 kill**，不能靠 bye 商量。
    ///   2. **必须等旧引擎死透再 startup()** —— 否则 `tryConnect()` 会又连回旧引擎，
    ///      形成「连上→发现旧→重启→又连上」的死循环。flock 单例还会让新引擎直接
    ///      `exit(0)`（锁被旧引擎持有），新引擎根本起不来。
    ///   3. **必须重置 sawHeartbeat** —— 否则重启后判定前提仍成立，立刻又判错配。
    ///
    /// 只在非驾驶状态调用（驾驶中突然失去引擎比版本错配更危险）。
    func relaunchStaleEngine() {
        let stale = engineProtocol
        let pid = enginePID
        engineClientLog("⚠️ 引擎协议版本不匹配：引擎 v\(stale) ≠ UI v\(Self.protocolVersion)")
        engineClientLog("→ 新命令会被旧引擎静默丢弃。终止 pid=\(pid) 并拉起新引擎")

        // 1) 断开本端连接（不再依赖 bye —— 旧引擎收到 bye 也不会退）
        readSource?.cancel()
        readSource = nil
        if socketFD >= 0 { close(socketFD); socketFD = -1 }
        detachShm()
        connectTimer?.cancel()
        connectTimer = nil
        // 2) 清空全部版本/连接状态，避免重启后立刻误判（坑 3）
        isActive = false
        isConnected = false
        engineProtocol = 0
        sawHeartbeat = false
        lastHeartbeat = .distantPast
        enginePID = 0
        // 3) 真 kill（坑 1）：先 SIGTERM，1 秒后仍在则 SIGKILL
        if pid > 0 {
            kill(pid, SIGTERM)
        }
        // 4) 轮询等旧引擎死透（坑 2），最多等 8 秒；死了才 startup()
        var waited = 0.0
        let poll = DispatchSource.makeTimerSource(queue: queue)
        poll.schedule(deadline: .now() + 0.4, repeating: 0.4, leeway: .milliseconds(50))
        poll.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                waited += 0.4
                let alive = pid > 0 && kill(pid, 0) == 0
                if alive && waited >= 1.2 {
                    kill(pid, SIGKILL)          // SIGTERM 不理会 → 强杀
                }
                if !alive || waited >= 8.0 {
                    poll.cancel()
                    if alive { engineClientLog("⚠️ 旧引擎 pid=\(pid) 8 秒未退出，仍继续尝试拉起") }
                    else { engineClientLog("旧引擎已退出，重新拉起…") }
                    self.engineRelaunching = false
                    self.startup()
                }
            }
        }
        poll.resume()
        self.relaunchPoll = poll
    }

    /// spawn 引擎子进程（同二进制 + --engine；stdout/stderr → 引擎日志）
    private func spawnEngine() -> Bool {
        let exeURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: exeURL.path) else {
            engineClientLog("可执行文件路径无效: \(exeURL.path)")
            return false
        }
        let process = Process()
        process.executableURL = exeURL
        process.arguments = ["--engine"]
        if let fh = FileHandle(forWritingAtPath: Self.engineLogPath) {
            fh.seekToEndOfFile()
            process.standardOutput = fh
            process.standardError = fh
        }
        do {
            try process.run()
            engineClientLog("spawn 引擎 pid=\(process.processIdentifier)")
            return true
        } catch {
            engineClientLog("spawn 失败: \(error)")
            return false
        }
    }

    // MARK: - socket 读（心跳）

    private func readSocket() {
        guard socketFD >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(socketFD, &buf, buf.count)
        if n > 0 {
            lineBuffer.append(contentsOf: buf[0..<n])
            while let nl = lineBuffer.firstIndex(of: 0x0A) {
                let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
                lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8) {
                    DispatchQueue.main.async { [weak self] in
                        self?.handleHeartbeatLine(line)
                    }
                }
            }
        } else {
            // 断开
            readSource?.cancel()
            readSource = nil
            if socketFD >= 0 { close(socketFD); socketFD = -1 }
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = false
                engineClientLog("与引擎的连接断开")
                self?.tryReconnectSoon()
            }
        }
    }

    private func tryReconnectSoon() {
        guard isActive else { return }
        connectAttempts = 0
        if connectTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.tryConnect() {
                        self.isConnected = true
                        engineClientLog("已重连引擎")
                        self.connectTimer?.cancel()
                        self.connectTimer = nil
                    }
                }
            }
            timer.resume()
            connectTimer = timer
        }
    }

    private func handleHeartbeatLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        guard type == "heartbeat" else { return }
        lastHeartbeat = Date()
        isConnected = true
        if let v = obj["isDriving"] as? Bool { engineIsDriving = v }
        if let v = obj["isStreaming"] as? Bool { engineIsStreaming = v }
        if let v = obj["fps"] as? Double { engineFPS = v }
        // 驾驶状态回传（引擎模式下 UI 不跑推理，面板/状态栏靠这些刷新）
        if let s = obj["modeRaw"] as? String, let m = DriveMode(rawValue: s) { engineMode = m }
        if let v = obj["speed"] as? Double { engineSpeed = v }
        if let v = obj["speedKmh"] as? Double { engineSpeedKmh = v }
        if let v = obj["confidence"] as? Double { engineConfidence = v }
        // 录制状态回传（引擎模式下真正的写盘在引擎进程，UI 只负责显示）
        if let v = obj["recording"] as? Bool { engineRecording = v }
        if let v = obj["frames"] as? Int { engineRecordFrames = v }
        // 协议版本：UI 重启后可能连上重编译前的旧引擎（旧引擎不发此字段 → 保持 0）
        if let v = obj["proto"] as? Int { engineProtocol = v }
        // 标记「已收到过心跳」：版本错配判定以此为前置，避免启动瞬间误判
        if !sawHeartbeat { sawHeartbeat = true }
        // 引擎重启检测：只在「已有 pid 且 pid 变了」时重新映射共享内存。
        // （首次心跳时 enginePID 还是 0，不能当成重启，否则会白白多映射一次）
        if let v = obj["pid"] as? Int32, enginePID != 0, v != enginePID {
            engineClientLog("引擎已重启（pid \(enginePID) → \(v)），重新映射共享内存")
            enginePID = v
            detachShm()
            attachShm()
        } else if let v = obj["pid"] as? Int32, enginePID == 0 {
            enginePID = v   // 首次记录，不重映射
        }
    }

    // MARK: - 共享内存读取

    /// 从共享内存拷贝到 CVPixelBuffer（池化复用；供 MetalGoose 插帧消费）
    private func copyIntoPixelBuffer(base: UnsafeMutableRawPointer, offset: Int,
                                     w: Int, h: Int) -> CVPixelBuffer? {
        if cvPool == nil || cvPoolW != w || cvPoolH != h {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                          attrs as CFDictionary, &pool) == kCVReturnSuccess else {
                return nil
            }
            cvPool = pool
            cvPoolW = w
            cvPoolH = h
        }
        guard let pool = cvPool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let dst = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let copyBytes = w * 4
        for r in 0..<h {
            // 目标可能有行填充，源侧共享内存是紧凑布局，逐行拷
            memcpy(dst.advanced(by: r * bpr), base.advanced(by: offset + r * copyBytes), copyBytes)
        }
        return pb
    }

    /// 取走上一步 poll() 产出的像素缓冲（消费一次；插帧模式用）
    func takePixelBuffer() -> CVPixelBuffer? {
        let b = pendingPixelBuffer
        pendingPixelBuffer = nil
        return b
    }

    private func attachShm() {
        guard shmBase == nil else { return }
        let fd = swift_shm_open(EngineFrameShm.name, O_RDONLY, 0)
        guard fd >= 0 else {
            engineClientLog("共享内存打开失败（引擎可能尚未创建）")
            return
        }
        var st = stat()
        fstat(fd, &st)
        let size = Int(st.st_size)
        guard size > 0, let p = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0),
              p != MAP_FAILED else {
            close(fd)
            engineClientLog("共享内存 mmap 失败")
            return
        }
        close(fd)   // mmap 后可关闭 fd，映射保持有效
        shmBase = p
        shmSize = size
        lastFrameSeq = 0
        engineClientLog("共享内存已映射 \(size / 1024 / 1024) MB")
    }

    private func detachShm() {
        if let p = shmBase {
            munmap(p, shmSize)
        }
        shmBase = nil
        shmSize = 0
        frameCache = nil
        lastFrameSeq = 0
    }

    /// 每 tick 调用：拉取最新帧与检测结果（无新帧则复用缓存）
    func poll() -> CGImage? {
        guard isActive else { return nil }
        // 心跳超时 → 标记失联（UI 显示层用）
        if isConnected, Date().timeIntervalSince(lastHeartbeat) > 3.0 {
            isConnected = false
            engineClientLog("⚠️ 引擎心跳超时（失联）")
        }
        guard let base = shmBase else { return frameCache }

        let seq = base.load(fromByteOffset: 40, as: UInt64.self)
        guard seq != lastFrameSeq else { return frameCache }
        lastFrameSeq = seq

        let activePage = base.load(fromByteOffset: 36, as: UInt32.self)
        let w = Int(base.load(fromByteOffset: 24, as: UInt32.self))
        let h = Int(base.load(fromByteOffset: 28, as: UInt32.self))
        let pageSize = Int(base.load(fromByteOffset: 72, as: UInt64.self))

        // ── 像素读取：按 UI 当前档位二选一 ──
        // 开插帧 → 读成 CVPixelBuffer（直接喂 MetalGoose，省一次大图构造）；
        // 普通显示 → 读成 CGImage（直绘 layer.contents）。
        if w > 0, h > 0, pageSize > 0 {
            let off = EngineFrameShm.pixelsOffset + Int(activePage) * pageSize
            if off + pageSize <= shmSize {
                if wantPixelBuffer {
                    pendingPixelBuffer = copyIntoPixelBuffer(base: base, offset: off, w: w, h: h)
                } else {
                    let src = base.advanced(by: off)
                    let data = Data(bytes: src, count: pageSize)
                    let cs = CGColorSpaceCreateDeviceRGB()
                    let info = CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                    if let provider = CGDataProvider(data: data as CFData),
                       let cg = CGImage(width: w, height: h, bitsPerComponent: 8,
                                        bitsPerPixel: 32, bytesPerRow: w * 4,
                                        space: cs, bitmapInfo: CGBitmapInfo(rawValue: info),
                                        provider: provider, decode: nil,
                                        shouldInterpolate: false, intent: .defaultIntent) {
                        frameCache = cg
                        frameCountSinceConnect += 1
                        if frameCountSinceConnect == 1 {
                            engineClientLog("收到引擎首帧 \(w)×\(h)（帧管道打通）")
                        }
                    }
                }
            }
        }

        // ── 检测结果 ──
        let n = Int(base.load(fromByteOffset: 56, as: UInt32.self))
        if n > 0 || !engineDetections.isEmpty {
            var dets: [Detection] = []
            for i in 0..<min(n, EngineFrameShm.detCapacity) {
                let o = EngineFrameShm.detOffset + i * EngineFrameShm.detStride
                let labelId = base.load(fromByteOffset: o, as: UInt32.self)
                let conf = base.load(fromByteOffset: o + 4, as: Float.self)
                let cx = base.load(fromByteOffset: o + 8, as: Float.self)
                let cy = base.load(fromByteOffset: o + 12, as: Float.self)
                let bw = base.load(fromByteOffset: o + 16, as: Float.self)
                let bh = base.load(fromByteOffset: o + 20, as: Float.self)
                let label: Detection.Label
                switch labelId {
                case 1: label = .car
                case 2: label = .pedestrian
                case 3: label = .sign
                default: label = .obstacle
                }
                // rawName：16 字节，遇 0 截断
                var nameBytes: [UInt8] = []
                let namePtr = base.advanced(by: o + 24).assumingMemoryBound(to: UInt8.self)
                for k in 0..<16 {
                    let b = namePtr[k]
                    if b == 0 { break }
                    nameBytes.append(b)
                }
                let rawName = String(bytes: nameBytes, encoding: .utf8) ?? "OBJ"
                dets.append(Detection(x: Double(cx), y: Double(cy),
                                      width: Double(bw), height: Double(bh),
                                      label: label, confidence: Double(conf),
                                      rawName: rawName))
            }
            engineDetections = dets
        }

        // ── 状态标志 ──
        let flags = base.load(fromByteOffset: 60, as: UInt32.self)
        engineIsDriving = (flags & 1) != 0
        engineIsStreaming = (flags & 2) != 0
        let fpsMilli = base.load(fromByteOffset: 64, as: UInt32.self)
        if fpsMilli > 0 { engineFPS = Double(fpsMilli) / 1000.0 }

        return frameCache
    }

    // MARK: - 命令

    func sendCommand(_ type: String, extra: [String: Any] = [:]) {
        guard socketFD >= 0 else { return }
        var obj: [String: Any] = ["type": type]
        for (k, v) in extra { obj[k] = v }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        let line = json + "\n"
        guard let data = line.data(using: .utf8) else { return }
        let fd = socketFD
        queue.async {
            _ = data.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress!, ptr.count)
            }
        }
    }

    /// 告知引擎切换画面档位：开插帧/要清晰画面 → 发全分辨率帧；否则发 480 宽缩略帧省带宽。
    func setUpscale(_ on: Bool) {
        sendCommand("upscale", extra: ["on": on])
    }

    /// UI 正常关闭前调用（引擎继续运行）
    func sendBye() {
        sendCommand("bye")
    }

    /// UI 正常退出前同步发送 bye：不走异步队列（进程即将退出，异步写可能来不及）。
    /// 引擎收到 bye 后不触发看门狗停车，保持抓屏推理等待下次重连。
    func sendByeSync() {
        guard isActive, socketFD >= 0 else { return }
        let line = "{\"type\":\"bye\"}\n"
        guard let data = line.data(using: .utf8) else { return }
        _ = data.withUnsafeBytes { ptr in
            write(socketFD, ptr.baseAddress!, ptr.count)
        }
        engineClientLog("UI 退出：已发送 bye（引擎继续运行，等待下次重连）")
    }
}
