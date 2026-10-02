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
    /// 3 = 共享内存新增**掩码区**（da/ll 位压缩网格 + letterbox 几何），
    ///     `pixelsOffset` 从 20480 后移到 28672。**这是布局变更**：
    ///     新旧混跑时旧 UI 会把掩码区当像素读 → 花屏，所以必须升版本，
    ///     让版本守卫强制重启引擎（`EngineClient:227` 的 stale 判据）。
    nonisolated static let protocolVersion = 3

    // ── UI 读取的状态 ──
    private(set) var isActive = false          // 引擎模式已激活（连接成功）
    private(set) var isConnected = false       // 心跳正常
    private(set) var engineIsDriving = false
    private(set) var engineIsStreaming = false
    private(set) var engineFPS: Double = 0
    private(set) var engineDetections: [Detection] = []

    // ── 引擎回传的掩码（协议 v3 新增）──
    /// 可行驶区（da）网格。UI 侧的 `MaskOverlay` 直接读它。
    /// 引擎模式下 UI 不跑 YOLOPX，掩码只能由引擎送过来（见 EngineMain 文件头）。
    private(set) var engineDrivableMask: MaskGrid = .empty
    /// 车道线（ll）网格
    private(set) var engineLaneMask: MaskGrid = .empty
    /// 掩码对应的 letterbox 几何（把网格还原到画面坐标要用）
    private(set) var engineMaskMetrics: LetterboxMetrics = .zero
    /// 引擎侧是否已降级（掩码不可信）
    private(set) var engineMaskDegraded: Bool = true
    /// 引擎侧车道线**单独**塌陷（显示层用：只压暗车道线，不连坐可行驶区）
    ///
    /// ⚠️ 2026-09-27：与 `engineMaskDegraded` 分开的原因见 YolopxEngine
    ///    里 `laneDegraded` 的说明 —— 车道线是细目标、天然贴近下限，
    ///    单一总开关会让它一塌陷就把可行驶区一起压暗到不可见。
    private(set) var engineLaneDegraded: Bool = true
    /// 引擎侧可行驶区**单独**塌陷（显示层用：只压暗可行驶区，不连坐车道线）
    private(set) var engineDrivableDegraded: Bool = true
    /// 最近一次解析到的掩码世代号（用于判断掩码是否新鲜）
    private(set) var engineMaskSeq: UInt64 = 0
    private(set) var lastHeartbeat = Date.distantPast
    private(set) var enginePID: Int32 = 0
    /// 引擎自报的协议版本（0 = 旧引擎，不发 proto 字段）
    private(set) var engineProtocol = 0
    /// 是否已经历过至少一次「连接激活 → 收到心跳」的完整周期。
    /// 只有它成立时才允许判定版本错配，避免启动瞬间误判。
    private(set) var sawHeartbeat = false

    // ── 内部 ──
    /// 当前 socket 文件描述符（-1 = 未连接）。
    /// 自检需要断言「未连接时 socketFD 为 -1」这条不变量。
    var socketFD: Int32 = -1
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
            // 强制本地模式：连"想连引擎"都不成立 → 断线重连轮询也不该启动
            wantsEngineMode = false
            engineClientLog("AURORA_UI_LOCAL=1 → 本地模式")
            return
        }
        wantsEngineMode = true
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
            // 断开（对端关闭 / read 出错）
            // ★ 2026-10-02：统一走 handleConnectionLoss，并**立刻就地取消读源**。
            //
            // 【为什么必须就地取消】实测（23:02:26 / 23:03:26 两次）：
            //   一次 kill 引擎，日志里刷出 12+ 条「连接断开」。
            //   原因是 `read()` 返回 0 后本函数直接返回，**但 readSource 仍活着**，
            //   于是同一轮事件反复投递 EOF，每次都往主队列塞一个断开回调。
            //   改前的旧代码把 `readSource?.cancel()` 放在 async 块里，同样来不及。
            //   现在：在**读队列上同步取消**，主队列那条只是状态收尾。
            readSource?.cancel()
            readSource = nil
            DispatchQueue.main.async { [weak self] in
                self?.handleConnectionLoss(reason: "read-eof")
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

    // MARK: - 连接丢失（2026-10-02 新增）

    /// 统一的「连接已死」处理。**三处调用**：心跳超时、写命令失败、读循环结束。
    ///
    /// ★ 修的是什么（用户 2026-10-02 实测报障「点了切档 UI 不变」）：
    ///
    /// 改前心跳超时只做了一件事 —— `isConnected = false`（一个**纯显示**标志）。
    /// `isActive` 仍是 true、`socketFD` 仍是旧值。后果是 UI 卡在一个**僵尸态**：
    ///   · `isActive` 有 16 个消费者（检测框/速度/掩码/限幅…）→ UI 继续把
    ///     **已经死掉的引擎**的陈旧数据当数据源，而不是回落本地推理；
    ///   · `sendCommand` 的 `guard socketFD >= 0` 照样放行 → 所有命令写进死 socket、
    ///     **静默失败**（用户看到 `[WIRE] config 下发` 日志，以为成功了）；
    ///   · 没有任何路径触发重连 → 这个状态**永久持续**，除非用户重启 App。
    ///
    /// 现在：关 socket、置 `isActive = false`（UI 立刻回落本地模式，功能不中断）、
    ///   并**启动重连轮询**，引擎回来了自动切回引擎模式 + 补发配置。
    ///
    /// - Parameter reason: 诊断用原因（进日志）
    func handleConnectionLoss(reason: String) {
        // ★ 幂等守卫：同一轮断开可能被多条路径同时报上来
        //   （读队列 EOF、poll 心跳超时、sendCommand 写失败）。
        //   第一条处理完就把 socketFD 置 -1，后续的自然返回。
        guard socketFD >= 0 else { return }
        let wasActive = isActive
        readSource?.cancel()
        readSource = nil
        if socketFD >= 0 { close(socketFD); socketFD = -1 }
        isActive = false
        isConnected = false
        lastHeartbeat = .distantPast
        if wasActive {
            engineClientLog("⚠️ 连接已死 → 回落本地模式（原因：\(reason)），并开始重连")
        }
        // 重连不依赖 isActive（那正是被我们置 false 的东西）——
        // 单独靠 wantsEngineMode 表达「用户仍然想要引擎模式」。
        startReconnectPolling()
    }

    /// 是否仍希望使用引擎模式。UI 正常启动即为 true；`AURORA_UI_LOCAL=1` 时为 false。
    /// 与 `isActive` 的区别：`isActive` = **当前是否已连上**，
    /// `wantsEngineMode` = **是否还想连**（连接断了但还想连 → true）。
    ///
    /// ★ 初值直接取自环境变量，而不是只在 `startup()` 里赋值。
    /// 理由：`startup()` 只在正常 App 路径被调用（`AuroraDriveApp.swift:209`）。
    /// 各种 `--xxx-selftest` 一次性路径不会调用它 —— 若初值恒为 true，
    /// 那么「AURORA_UI_LOCAL=1 却仍可能启动重连轮询」就是个隐患。
    /// 让初值与 `startup()` 的判定同源，两边永远一致。
    private(set) var wantsEngineMode: Bool =
        ProcessInfo.processInfo.environment["AURORA_UI_LOCAL"] != "1"

    /// 连接断开后的重连轮询（独立于 isActive，与启动期的轮询同节奏）
    private func startReconnectPolling() {
        guard wantsEngineMode, connectTimer == nil else { return }
        connectAttempts = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connectAttempts += 1
                if self.tryConnect() {
                    self.activate()          // activate() 里会调 onActivated → 补发配置
                    self.connectTimer?.cancel()
                    self.connectTimer = nil
                } else if self.connectAttempts >= 40 {   // 20 秒仍连不上 → 停轮询，保持本地模式
                    engineClientLog("重连 20 秒未成功 → 保持本地模式")
                    self.connectTimer?.cancel()
                    self.connectTimer = nil
                }
            }
        }
        timer.resume()
        connectTimer = timer
    }

    /// 每 tick 调用：拉取最新帧与检测结果（无新帧则复用缓存）
    func poll() -> CGImage? {
        guard isActive else { return nil }
        // 心跳超时 → ★ 判定连接已死并回落（改前只置 isConnected，见 handleConnectionLoss 注释）
        if isConnected, Date().timeIntervalSince(lastHeartbeat) > 3.0 {
            engineClientLog("⚠️ 引擎心跳超时（3s 无心跳）")
            handleConnectionLoss(reason: "heartbeat-timeout")
            return nil
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

        // ── 掩码区（协议 v3）──
        //
        // 为什么用「世代号变化才解析」而不是每帧无条件解析：
        //   引擎侧 YOLOPX 是 15Hz，而 tick 是 30Hz。掩码只在 YOLOPX 出结果时更新，
        //   无条件解析会让一半的帧在解重复数据（每帧要展开 2×3200 字节位图
        //   = 51200 次位运算）。seq 没变就直接跳过。
        //
        // 为什么 seq 变化时**必须**整体重建而不是原地改：
        //   MaskGrid 是 let 属性的 struct，且 at() 有长度守卫；
        //   重建一份新的能保证 cells.count == width*height 这个不变式。
        // ⚠️ 安全门（必须）：掩码区的偏移(constant)是按 **协议 v3 的布局** 算的，
        //    但共享内存是**引擎**创建的，UI 只是映射了它。如果引擎还是旧版（v2，
        //    pixelsOffset=20480，总长更小），按 v3 偏移去读掩码会读到 mmap 之外
        //    → **SIGSEGV 直接崩掉 UI 进程**。
        //
        //    版本守卫（EngineMain 心跳里的 proto）确实存在，但它在 tickEngineMode
        //    里的位置**晚于**本次 poll() —— 先读后查，来不及拦。
        //    所以在读取点做**物理边界校验**：映射长度不够就整个跳过。
        //    这是最后一道防线，比版本号可靠（版本号是"约定"，长度是"事实"）。
        let maskRegionEnd = EngineFrameShm.maskOffset + EngineFrameShm.maskRegionBytes
        let maskReadable = shmSize >= maskRegionEnd
        let maskSeq = maskReadable ? base.load(fromByteOffset: 80, as: UInt64.self) : engineMaskSeq
        if maskReadable, maskSeq != engineMaskSeq {
            engineMaskSeq = maskSeq
            let flags = base.load(fromByteOffset: 104, as: UInt32.self)
            engineMaskDegraded = (flags & 1) != 0
            // bit2/bit3：分层塌陷标志。旧引擎（协议 v3 早期版本）不发这两个位，
            // 那时它们恒为 0 → 两层都不会被压暗。这是**安全的降级方向**：
            // 显示层偏亮（能看见），而不是偏暗（看不见）。
            engineLaneDegraded = (flags & 4) != 0
            engineDrivableDegraded = (flags & 8) != 0
            let maskValid = (flags & 2) != 0
            if maskValid {
                let dw = Int(base.load(fromByteOffset: 88, as: UInt32.self))
                let dh = Int(base.load(fromByteOffset: 92, as: UInt32.self))
                let lw = Int(base.load(fromByteOffset: 96, as: UInt32.self))
                let lh = Int(base.load(fromByteOffset: 100, as: UInt32.self))
                let ratio = Double(base.load(fromByteOffset: 108, as: Float.self))
                let padX = Int(base.load(fromByteOffset: 112, as: UInt32.self))
                let padY = Int(base.load(fromByteOffset: 116, as: UInt32.self))
                let srcW = Int(base.load(fromByteOffset: 120, as: UInt32.self))
                let srcH = Int(base.load(fromByteOffset: 124, as: UInt32.self))
                // 128/132：letterbox 内容区尺寸。
                //
                // ⚠️ 2026-09-28：这两格是**这次才补进协议**的。此前这里硬填
                //    `newW: 0, newH: 0`，而 `MaskOverlay` 当时用
                //    `guard metrics.newW > 0` 当绘制守卫 → 引擎模式下掩码全不画
                //    （用户："只能看到检测框，看不到可行驶区域和车道线"）。
                //    现在协议真的传了，这两个值就是真实几何。
                //
                // 兼容说明：旧引擎不写这两格（内容为 0），此时 newW/newH 为 0。
                // 但这**不再影响可见性** —— MaskOverlay 已改为不依赖 newW 判断
                // 能否绘制（绘制数学本来也不需要它）。这是刻意的双保险。
                let newW = Int(base.load(fromByteOffset: 128, as: UInt32.self))
                let newH = Int(base.load(fromByteOffset: 132, as: UInt32.self))

                // 尺寸合法性：网格不得超过协议上限（越界会读到像素区）
                if dw > 0, dh > 0, dw <= EngineFrameShm.maskGridMax,
                   dh <= EngineFrameShm.maskGridMax, lw >= 0, lh >= 0,
                   lw <= EngineFrameShm.maskGridMax, lh <= EngineFrameShm.maskGridMax {
                    engineDrivableMask = Self.readMask(base: base,
                                                       offset: EngineFrameShm.maskOffset,
                                                       w: dw, h: dh)
                    engineLaneMask = lw > 0 && lh > 0
                        ? Self.readMask(base: base,
                                        offset: EngineFrameShm.maskOffset + EngineFrameShm.maskBytes,
                                        w: lw, h: lh)
                        : .empty
                    engineMaskMetrics = LetterboxMetrics(ratio: ratio, padX: padX, padY: padY,
                                                         padBottom: 0, newW: newW, newH: newH,
                                                         srcW: srcW, srcH: srcH)
                }
            } else {
                // 引擎明确表示"本帧没有掩码"（例如未开始驾驶 / 模型未加载）
                engineDrivableMask = .empty
                engineLaneMask = .empty
            }
        }

        // ── 状态标志 ──
        let flags = base.load(fromByteOffset: 60, as: UInt32.self)
        engineIsDriving = (flags & 1) != 0
        engineIsStreaming = (flags & 2) != 0
        let fpsMilli = base.load(fromByteOffset: 64, as: UInt32.self)
        if fpsMilli > 0 { engineFPS = Double(fpsMilli) / 1000.0 }

        return frameCache
    }

    // MARK: - 掩码解码

    /// 从共享内存读一个位压缩掩码并展开成 `MaskGrid`。
    ///
    /// 与引擎侧 `EngineFrameShm.writeMask` 严格对称：
    ///   · 每行 `(w+7)/8` 字节
    ///   · 第 y 行第 x 列对应 `ptr[y*bytesPerRow + x/8]` 的第 `x%8` 位
    ///
    /// 展开成 UInt8 数组（0/1）而不是保留位图，是为了让 `MaskGrid.at()`
    /// 及其长度守卫原样可用 —— 下游 `LaneFallback` / `MaskOverlay` 都按
    /// `cells.count == width*height` 的前提写。这点内存（25.6KB×2）换来
    /// 零下游改动，值得。
    private nonisolated static func readMask(base: UnsafeRawPointer,
                                            offset: Int,
                                            w: Int, h: Int) -> MaskGrid {
        guard w > 0, h > 0 else { return .empty }
        let bytesPerRow = (w + 7) / 8
        var cells = [UInt8](repeating: 0, count: w * h)
        let ptr = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let rowBase = y * bytesPerRow
            for x in 0..<w {
                if ptr[rowBase + x / 8] & UInt8(1 << (x % 8)) != 0 {
                    cells[y * w + x] = 1
                }
            }
        }
        return MaskGrid(width: w, height: h, cells: cells)
    }

    // MARK: - 命令

    /// 向引擎发一条命令。
    ///
    /// ★ 2026-10-02 改：**返回值从 Void 改为 Bool**，并在写入后**同步检查 write() 的结果**。
    ///
    /// 【为什么必须改】改前它是「静默失败」的：
    ///   · `guard socketFD >= 0 else { return }` —— 引擎没连上就一声不吭地走人；
    ///   · `queue.async { _ = write(...) }` —— **写入结果被丢弃**，失败也无人知晓。
    ///   后果被实测抓到（用户 2026-10-02 报「点了切档但 UI 不变」）：
    ///     `ControlWiring.pushConfig` 打完 `[WIRE] config 下发` 日志就以为成功了，
    ///     而配置其实丢在死 socket 里 —— 日志与事实完全相反，排查时极具误导性。
    ///
    /// 【现在返回什么】true = 数据确实写进了内核发送缓冲；false = 没发（未连接/序列化失败/写入出错）。
    ///   调用方据此决定要不要重试（见 `pushEngineConfigIfChanged`）。
    ///
    /// 【为什么改同步写】原来 `queue.async` 异步写，返回值根本拿不到。
    ///   命令都是几十字节的小包（config/heartbeat 应答级别），同步 write 的耗时
    ///   在微秒量级，**不会**对 30Hz 主循环造成可测量的影响；而换来的是
    ///   「发送成功与否」这个**唯一能让重试逻辑成立**的事实。
    ///
    /// - Returns: 是否真的发出去（false 时调用方应当保留待发状态、稍后重试）
    @discardableResult
    func sendCommand(_ type: String, extra: [String: Any] = [:]) -> Bool {
        guard socketFD >= 0 else { return false }
        var obj: [String: Any] = ["type": type]
        for (k, v) in extra { obj[k] = v }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: jsonData, encoding: .utf8) else { return false }
        let line = json + "\n"
        guard let data = line.data(using: .utf8) else { return false }
        let fd = socketFD
        // 同步写 + 检查返回值。写入中途被信号打断（EINTR）时重试剩余部分。
        var sent = 0
        let total = data.count
        var ok = true
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { ok = false; return }
            while sent < total {
                let n = write(fd, base + sent, total - sent)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue                       // 被信号打断 → 重试
                } else {
                    // 写失败（EPIPE / ECONNRESET / EAGAIN …）
                    // → 判定连接已死：关 socket 并置失联，让上层自动重连。
                    //   这一条同时修掉了「引擎死了 UI 不知道」的旧问题。
                    ok = false
                    break
                }
            }
        }
        if !ok {
            engineClientLog("⚠️ 命令发送失败（\(type)）—— 判定连接已死，转入重连")
            // 复用既有的断开语义：关 fd、置 isActive=false、触发重连
            self.handleConnectionLoss(reason: "send-\(type)-failed")
        }
        return ok
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
