// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  EngineMain.swift — 后台驾驶引擎（--engine 模式）
//
//  由 @main AuroraDriveLauncher 在进程最前端分流进入：不触碰 SwiftUI、
//  不创建窗口、不跑 NSApp.run()，在纯后台进程里运行完整驾驶闭环。
//  TCC 权限经进程链继承（父进程已授权 → 本进程自动继承，无弹窗）。
//
//  组成：
//   1) flock 单例锁      —— 防双引擎同时注入按键
//   2) TCC 自检           —— ax + screen 任一 false 立即 fail-fast
//                            （AURORA_ENGINE_DIAG_SKIP_TCC=1 诊断旁路，
//                              仅供无 TCC 环境验证非权限逻辑，正常路径禁用）
//   3) beginActivity      —— 防 App Nap 冻结
//   4) Unix domain socket —— 命令/心跳（~/Library/Application Support/AuroraDrive/engine.sock）
//   5) 共享内存帧管道     —— 帧头 + 检测结果 + BGRA 双缓冲（引擎写 / UI 读）
//   6) DriveState 闭环    —— 照搬主程序组装（同一份类代码）+ 30Hz DispatchSource tick
//   7) 信号处理           —— SIGTERM/SIGINT 退出前必先 releaseAll（防游戏内键卡死）
// ============================================================================

import Foundation
import Darwin
import AppKit
import ApplicationServices

// shm_open 在 C 声明为可变参数函数（oflag 含 O_CREAT 时才传 mode），
// Swift 无法直接导入可变参数 C 函数；此处桥接为固定 3 参版本。
// internal：EngineClient（UI 侧）也要用同一桥接。
@_silgen_name("shm_open")
func swift_shm_open(_ name: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32
@_silgen_name("shm_unlink")
func swift_shm_unlink(_ name: UnsafePointer<CChar>) -> Int32

// MARK: - 引擎日志

/// 引擎日志：同时写 stdout 与 ~/Library/Logs/AuroraEngine.log
func engineLog(_ msg: String) {
    let ts = SelfTimestamp()
    let line = "[\(ts)] \(msg)\n"
    FileHandle.standardOutput.write(line.data(using: .utf8) ?? Data())
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AuroraEngine.log").path
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

private func SelfTimestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - 共享内存帧管道

/// 布局（字节偏移）：
///   0    magic u32            (0x41555246 "AURF")
///   4    version u32          (=1)
///   8    headerSize u32       (=4096)
///   12   detOffset u32        (=4096)
///   16   detCapacity u32      (=256)
///   20   detStride u32        (=64)
///   24   frameWidth u32
///   28   frameHeight u32
///   32   generation u32       (分辨率变化 +1)
///   36   activePage u32       (0/1；翻转即新帧就绪)
///   40   frameSeq u64
///   48   timestampNs u64
///   56   detectionCount u32
///   60   flags u32            (bit0 isDriving / bit1 isStreaming)
///   64   fpsMilli u32         (fps×1000)
///   68   enginePid u32
///   72   pageSize u64
/// 4096   检测结果区：detCapacity×detStride（每条：labelId u32 / conf f32 /
///        cx f32 / cy f32 / w f32 / h f32 / rawName 16 bytes / 预留）
/// 20480  像素页 A
/// 20480+pageSize  像素页 B
final class EngineFrameShm {

    static let name = "/aurora_frame_v1"
    static let headerSize = 4096
    static let detOffset = 4096
    static let detCapacity = 256
    static let detStride = 64
    static let pixelsOffset = 20480
    static let maxWidth = 4096
    static let maxHeight = 2304

    private let fd: Int32
    private let base: UnsafeMutableRawPointer
    private let totalSize: Int
    private var currentPageSize = 0
    private var frameSeq: UInt64 = 0
    private var generation: UInt32 = 1

    /// 已发布的帧序号（统计/验证用）
    var publishedSeq: UInt64 { frameSeq }

    init?() {
        let pageMax = EngineFrameShm.maxWidth * EngineFrameShm.maxHeight * 4
        let size = EngineFrameShm.pixelsOffset + pageMax * 2
        // 引擎是共享内存的唯一创建者：启动时先清掉上次残留对象，
        // 避免旧对象权限/尺寸异常导致打开失败（已实测踩坑）。
        _ = swift_shm_unlink(EngineFrameShm.name)
        let fd = swift_shm_open(EngineFrameShm.name, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            engineLog("[ENGINE] shm_open 失败 errno=\(errno)")
            return nil
        }
        if ftruncate(fd, off_t(size)) != 0 {
            engineLog("[ENGINE] shm ftruncate 失败 errno=\(errno)")
            close(fd)
            return nil
        }
        guard let p = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              p != MAP_FAILED else {
            engineLog("[ENGINE] shm mmap 失败 errno=\(errno)")
            close(fd)
            return nil
        }
        self.fd = fd
        self.base = p
        self.totalSize = size

        // 写头部常量
        storeU32(0, 0x41555246)                    // magic
        storeU32(4, 1)                             // version
        storeU32(8, UInt32(EngineFrameShm.headerSize))
        storeU32(12, UInt32(EngineFrameShm.detOffset))
        storeU32(16, UInt32(EngineFrameShm.detCapacity))
        storeU32(20, UInt32(EngineFrameShm.detStride))
        storeU32(68, UInt32(getpid()))
    }

    deinit {
        munmap(base, totalSize)
        close(fd)
    }

    private func storeU32(_ off: Int, _ v: UInt32) {
        base.storeBytes(of: v, toByteOffset: off, as: UInt32.self)
    }
    private func storeU64(_ off: Int, _ v: UInt64) {
        base.storeBytes(of: v, toByteOffset: off, as: UInt64.self)
    }

    /// 发布一帧（成品画面 + 检测结果 + 状态）
    /// fullFrame 非空时用全分辨率帧（插帧/清晰显示用），否则用 480 宽缩略帧。
    func publish(image: CGImage?, detections: [Detection],
                 fps: Double, isDriving: Bool, isStreaming: Bool,
                 fullFrame: CVPixelBuffer? = nil) {

        // ── 检测结果区 ──
        let n = min(detections.count, EngineFrameShm.detCapacity)
        for i in 0..<n {
            let d = detections[i]
            let off = EngineFrameShm.detOffset + i * EngineFrameShm.detStride
            var labelId: UInt32 = 0
            switch d.label {
            case .car: labelId = 1
            case .pedestrian: labelId = 2
            case .sign: labelId = 3
            case .obstacle: labelId = 4
            }
            base.storeBytes(of: labelId, toByteOffset: off + 0, as: UInt32.self)
            base.storeBytes(of: Float(d.confidence), toByteOffset: off + 4, as: Float.self)
            base.storeBytes(of: Float(d.x), toByteOffset: off + 8, as: Float.self)
            base.storeBytes(of: Float(d.y), toByteOffset: off + 12, as: Float.self)
            base.storeBytes(of: Float(d.width), toByteOffset: off + 16, as: Float.self)
            base.storeBytes(of: Float(d.height), toByteOffset: off + 20, as: Float.self)
            // rawName：固定 16 字节，UTF8 截断
            let nameBytes = Array(d.rawName.utf8.prefix(15))
            let namePtr = base.advanced(by: off + 24).assumingMemoryBound(to: UInt8.self)
            for k in 0..<16 { namePtr[k] = 0 }
            for (k, b) in nameBytes.enumerated() { namePtr[k] = b }
        }

        // ── 像素区（双缓冲：写非活动页）──
        // 优先用全分辨率帧（插帧 / 清晰显示需要），否则用 480 宽缩略帧
        if let pb = fullFrame {
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            if w > 0, h > 0, w <= EngineFrameShm.maxWidth, h <= EngineFrameShm.maxHeight {
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                if let srcBase = CVPixelBufferGetBaseAddress(pb) {
                    let srcBPR = CVPixelBufferGetBytesPerRow(pb)
                    let pageSize = w * h * 4
                    if pageSize != currentPageSize {
                        currentPageSize = pageSize
                        generation += 1
                        storeU32(32, generation)
                        storeU64(72, UInt64(pageSize))
                    }
                    let active = base.load(fromByteOffset: 36, as: UInt32.self)
                    let writePage = active == 0 ? 1 : 0
                    let dest = base.advanced(by: EngineFrameShm.pixelsOffset + writePage * currentPageSize)
                    let copyBytes = w * 4
                    for r in 0..<h {
                        // 源可能有行填充（bytesPerRow > w*4），逐行拷到紧凑布局
                        memcpy(dest.advanced(by: r * copyBytes),
                               srcBase.advanced(by: r * srcBPR), copyBytes)
                    }
                    storeU32(24, UInt32(w))
                    storeU32(28, UInt32(h))
                    storeU32(36, UInt32(writePage))   // 发布：翻转活动页
                }
            }
        } else if let img = image {
            let w = img.width
            let h = img.height
            if w > 0, h > 0, w <= EngineFrameShm.maxWidth, h <= EngineFrameShm.maxHeight {
                let pageSize = w * h * 4
                if pageSize != currentPageSize {
                    currentPageSize = pageSize
                    generation += 1
                    storeU32(32, generation)
                    storeU64(72, UInt64(pageSize))
                }
                let active = base.load(fromByteOffset: 36, as: UInt32.self)
                let writePage = active == 0 ? 1 : 0
                let destOff = EngineFrameShm.pixelsOffset + writePage * currentPageSize
                let dest = base.advanced(by: destOff)
                // 快路径：源 CGImage 由 CaptureEngine 经 CGDataProvider 零拷贝包装
                // uiBuf（CaptureEngine.swift:409-413），格式与目标页完全一致——同为
                // 32BGRA premultipliedFirst + byteOrder32Little，色彩空间同为 DeviceRGB，
                // 且 ctx.draw 的目标矩形 = 源尺寸 → 无缩放 → 原路径只做恒等格式转换，
                // 却要走完整 CG 绘制管线（实测占引擎 tick 主线程 ~78.6%）。
                // 直接 memcpy 即可。注意源 bytesPerRow 来自 CVPixelBuffer 行距，
                // 可能含对齐填充，必须逐行拷贝。
                if let data = img.dataProvider?.data, let src = CFDataGetBytePtr(data) {
                    let srcBPR = img.bytesPerRow
                    let copyBytes = w * 4
                    if srcBPR == copyBytes {
                        memcpy(dest, src, copyBytes * h)
                    } else {
                        for r in 0..<h {
                            memcpy(dest + r * copyBytes, src + r * srcBPR, copyBytes)
                        }
                    }
                    storeU32(24, UInt32(w))
                    storeU32(28, UInt32(h))
                    storeU32(36, UInt32(writePage))   // 发布：翻转活动页
                } else {
                    // 兜底：dataProvider 不可读（理论不发生，CaptureEngine 恒有 provider）
                    // 时回退原 CGContext 绘制路径，功能零损失。
                    let cs = CGColorSpaceCreateDeviceRGB()
                    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                    if let ctx = CGContext(data: dest, width: w, height: h,
                                           bitsPerComponent: 8, bytesPerRow: w * 4,
                                           space: cs, bitmapInfo: bitmapInfo) {
                        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                        storeU32(24, UInt32(w))
                        storeU32(28, UInt32(h))
                        storeU32(36, UInt32(writePage))   // 发布：翻转活动页
                    }
                }
            }
        }

        // ── 头部状态 ──
        frameSeq += 1
        storeU64(40, frameSeq)
        storeU64(48, UInt64(DispatchTime.now().uptimeNanoseconds))
        storeU32(56, UInt32(n))
        var flags: UInt32 = 0
        if isDriving { flags |= 1 }
        if isStreaming { flags |= 2 }
        storeU32(60, flags)
        storeU32(64, UInt32(max(0, fps) * 1000))
    }
}

// MARK: - Unix domain socket 服务

/// 命令/心跳通道。单客户端；新连接自动替换旧连接（UI 重开重连场景）。
final class EngineSocketServer {

    private let path: String
    private let queue = DispatchQueue(label: "aurora.engine.socket", qos: .userInteractive)
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clientSource: DispatchSourceRead?
    private var lineBuffer = Data()

    var onLine: ((String) -> Void)?
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?

    private(set) var hasClient = false

    init(path: String) {
        self.path = path
    }

    func start() -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        unlink(path)   // 清掉上次残留的 socket 文件

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            engineLog("[ENGINE] socket() 失败 errno=\(errno)")
            return false
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            engineLog("[ENGINE] socket 路径过长")
            close(fd)
            return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                memcpy(dst, src.baseAddress!, src.count)
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, addrLen)
            }
        }
        guard bindResult == 0 else {
            engineLog("[ENGINE] bind 失败 errno=\(errno)")
            close(fd)
            return false
        }
        guard listen(fd, 4) == 0 else {
            engineLog("[ENGINE] listen 失败 errno=\(errno)")
            close(fd)
            return false
        }
        // 确保 UI 端能连（同用户 0600）
        chmod(path, 0o600)

        self.listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        src.resume()
        self.listenSource = src
        engineLog("[ENGINE] socket 监听就绪: \(path)")
        return true
    }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        // 新连接替换旧连接（UI 重开重连）：
        // 旧连接由它自己的 cancel handler 关闭（只关它自己的 fd），
        // 绝不在这里按 clientFD 关——cancel 是异步的，若按共享变量关会误关新连接。
        if let old = clientSource {
            clientSource = nil
            old.cancel()
        }
        clientFD = fd
        lineBuffer.removeAll(keepingCapacity: true)
        hasClient = true
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            self?.readClient(fd: fd)
        }
        src.setCancelHandler {
            close(fd)   // 只关本连接的 fd
        }
        src.resume()
        clientSource = src
        engineLog("[ENGINE] UI 已连接")
        onClientConnected?()
    }

    private func readClient(fd: Int32) {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            lineBuffer.append(contentsOf: buf[0..<n])
            // 按行切分
            while let nl = lineBuffer.firstIndex(of: 0x0A) {
                let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
                lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8) {
                    onLine?(line)
                }
            }
        } else {
            // EOF 或错误 → 本连接断开（fd 由 cancel handler 关闭）
            if clientFD == fd { clientFD = -1 }
            clientSource?.cancel()
            clientSource = nil
            hasClient = false
            engineLog("[ENGINE] UI 连接断开")
            onClientDisconnected?()
        }
    }

    func send(_ line: String) {
        queue.async { [weak self] in
            guard let self, self.clientFD >= 0 else { return }
            let data = Array((line + "\n").utf8)
            _ = data.withUnsafeBufferPointer { ptr in
                write(self.clientFD, ptr.baseAddress!, ptr.count)
            }
        }
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        clientSource?.cancel()
        clientSource = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }
}

// MARK: - 引擎全局（MainActor 隔离状态）

enum EngineGlobals {
    @MainActor static var state: DriveState?
    @MainActor static var shm: EngineFrameShm?
    @MainActor static var socket: EngineSocketServer?
    @MainActor static var clientSaidBye = false
    /// SIGTERM/SIGINT 置位（由主流 tick 检查后安全停车退出）
    nonisolated(unsafe) static var shutdownRequested = false
    /// UI 是否请求「全分辨率帧」（开了插帧才需要，否则发 480 宽省带宽）
    @MainActor static var wantFullFrame = false
    /// 最新全分辨率帧（采集线程写 / 主线程读，用锁保护；覆盖式=天然跳帧）
    nonisolated(unsafe) static var latestFullFrame: CVPixelBuffer?
    nonisolated(unsafe) static let latestFullFrameLock = NSLock()
}

// MARK: - 引擎主入口

enum EngineMain {

    static func run() -> Never {
        engineLog("[ENGINE] 启动 --engine 模式 pid=\(getpid())")

        let home = FileManager.default.homeDirectoryForCurrentUser
        let appSupport = home.appendingPathComponent("Library/Application Support/AuroraDrive")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        // ── 1. 单例锁（flock 独占；进程退出自动释放）──
        let lockPath = appSupport.appendingPathComponent("engine.lock").path
        let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else {
            engineLog("[ENGINE] 无法创建锁文件 \(lockPath)")
            exit(3)
        }
        if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            engineLog("[ENGINE] 已有引擎实例在运行（flock 失败），本进程退出")
            exit(0)
        }
        ftruncate(lockFD, 0)
        let pidStr = "\(getpid())\n"
        _ = pidStr.withCString { write(lockFD, $0, strlen($0)) }

        // ── 2. TCC 自检（fail-fast）──
        let axOK = AXIsProcessTrusted()
        let screenOK = CGPreflightScreenCaptureAccess()
        let diagSkip = ProcessInfo.processInfo.environment["AURORA_ENGINE_DIAG_SKIP_TCC"] == "1"
        engineLog("[ENGINE] TCC 自检 ax=\(axOK) screen=\(screenOK)")
        if !(axOK && screenOK) {
            if diagSkip {
                engineLog("[ENGINE] ⚠️ 诊断旁路生效（AURORA_ENGINE_DIAG_SKIP_TCC=1），继续运行以便验证非权限逻辑")
            } else {
                engineLog("[ENGINE] TCC 权限不足，fail-fast 退出（权限须由父进程链继承）")
                exit(2)
            }
        }

        // ── Game Mode 对抗（持久战）：静音音频 + 每 3s 重新主张 ──
        // 引擎进程是跑检测的那个，最需要 audible 维度与持续重主张
        GameModeDefender.shared.start()

        // ── 3. 防冻结 ──
        let napToken = ProcessInfo.processInfo.beginActivity(
            options: [.latencyCritical, .userInteractive, .idleSystemSleepDisabled],
            reason: "AuroraDrive 后台驾驶引擎：持续 30Hz 抓屏推理与按键注入")
        _ = napToken   // 必须持有，否则 activity 立即释放
        if setpriority(PRIO_PROCESS, 0, -20) == 0 {
            engineLog("[ENGINE] 进程优先级 nice=-20")
        }

        // ── 4. 信号处理（先 ignore 默认行为，交给 DispatchSource）──
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let signalQueue = DispatchQueue(label: "aurora.engine.signal")
        for sig in [SIGTERM, SIGINT] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            src.setEventHandler {
                engineLog("[ENGINE] 收到信号 \(sig)，请求安全停车退出")
                EngineGlobals.shutdownRequested = true
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        EngineMain.performShutdown(reason: "signal \(sig)")
                    }
                }
            }
            src.resume()
            signalSources.append(src)
        }

        // ── 5. socket ──
        let socketPath = appSupport.appendingPathComponent("engine.sock").path
        let server = EngineSocketServer(path: socketPath)
        server.onLine = { line in
            EngineMain.handleCommand(line, server: server)
        }
        server.onClientDisconnected = {
            // 看门狗（步骤4 完善）：异常断开且未收到 bye → 3 秒重连窗口 → 停车
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if EngineGlobals.clientSaidBye {
                        engineLog("[ENGINE] UI 主动关闭（bye），引擎继续运行等待重连")
                    } else {
                        engineLog("[ENGINE] UI 连接异常断开，进入 3 秒重连窗口")
                        EngineMain.startReconnectWindow()
                    }
                    // 无论主动关闭还是异常断开，都启动「无人使用倒计时」：
                    // 30 秒内没有 UI 重连 → 引擎自动安全退出（不再常驻占资源）。
                    EngineMain.startIdleExitCountdown()
                }
            }
        }
        server.onClientConnected = {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    EngineMain.cancelReconnectWindow()
                    EngineMain.cancelIdleExitCountdown()
                    EngineGlobals.clientSaidBye = false
                    EngineMain.sendHeartbeat(reason: "client-connected")
                }
            }
        }
        guard server.start() else {
            engineLog("[ENGINE] socket 启动失败，退出")
            exit(4)
        }

        // ── 6. 共享内存 ──
        guard let shm = EngineFrameShm() else {
            engineLog("[ENGINE] 共享内存创建失败，退出")
            exit(5)
        }

        // ── 7. DriveState 闭环 + 30Hz tick（照搬 ContentView 驱动方式）──
        MainActor.assumeIsolated {
            EngineGlobals.state = DriveState()
            EngineGlobals.shm = shm
            EngineGlobals.socket = server
            // 全分辨率帧接线（供 UI 插帧 / 清晰显示）：
            // 覆盖 DriveState 默认的「喂本进程 upscaleHost」接线 —— 引擎没有窗口/MTKView，
            // 插帧渲染在 UI 进程做，引擎只负责把全分辨率帧送过去。
            EngineGlobals.state?.captureEngine.onUpscaleFrame = { pb in
                EngineGlobals.latestFullFrameLock.lock()
                EngineGlobals.latestFullFrame = pb
                EngineGlobals.latestFullFrameLock.unlock()
            }
            // 门禁：UI 经 socket 的 upscale 命令（wantFullFrame）实时控制——
            // 关闭时帧回调里连全分辨率拷贝都不做（isUpscaleWanted 在拷贝前求值）。
            EngineGlobals.state?.captureEngine.isUpscaleWanted = { EngineGlobals.wantFullFrame }
            // 诊断（仅供无按键权限的环境验证帧管道）：
            // 只启动抓屏、不注入按键，用来端到端验证「采集 → 共享内存 → UI」这条链路。
            // 生产路径不受影响（默认不设该变量）。
            if ProcessInfo.processInfo.environment["AURORA_ENGINE_DIAG_CAPTURE_ONLY"] == "1" {
                EngineGlobals.state?.captureEngine.start()
                engineLog("[ENGINE] 诊断：仅抓屏模式（不注入按键），用于验证帧管道")
            }
        }
        engineLog("[ENGINE] DriveState 已创建")

        let tickQueue = DispatchQueue(label: "aurora.engine.tick", qos: .userInteractive)
        let tickTimer = DispatchSource.makeTimerSource(queue: tickQueue)
        tickTimer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .nanoseconds(0))
        tickTimer.setEventHandler {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    EngineMain.tickOnce()
                }
            }
        }
        tickTimer.resume()
        engineTicker = tickTimer

        // ── 8. 心跳（1Hz）──
        let hbQueue = DispatchQueue(label: "aurora.engine.heartbeat")
        let hbTimer = DispatchSource.makeTimerSource(queue: hbQueue)
        hbTimer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(50))
        hbTimer.setEventHandler {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if EngineGlobals.shutdownRequested {
                        EngineMain.performShutdown(reason: "tick-detected")
                        return
                    }
                    EngineMain.sendHeartbeat(reason: "periodic")
                    heartbeatCount += 1
                    // 每 5 秒输出一条管道统计，便于无人值守验证
                    if heartbeatCount % 5 == 0 {
                        let seq = EngineGlobals.shm?.publishedSeq ?? 0
                        let hasFrame = EngineGlobals.state?.currentFrameCG != nil
                        engineLog("[ENGINE] 统计: seq=\(seq) 有帧=\(hasFrame) det=\(EngineGlobals.state?.yoloEngine.detections.count ?? 0) driving=\(EngineGlobals.state?.isDriving ?? false)")
                    }
                }
            }
        }
        hbTimer.resume()
        engineHeartbeat = hbTimer

        engineLog("[ENGINE] 就绪（tick 30Hz / 心跳 1Hz / socket / shm）")
        dispatchMain()   // 永不返回
    }

    // MARK: - 定时器句柄（必须持有）
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []
    nonisolated(unsafe) private static var engineTicker: DispatchSourceTimer?
    nonisolated(unsafe) private static var engineHeartbeat: DispatchSourceTimer?
    nonisolated(unsafe) private static var reconnectWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private static var idleExitWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private static var heartbeatCount = 0

    // MARK: - tick 与发布

    @MainActor
    static func tickOnce() {
        guard let st = EngineGlobals.state else { return }
        st.tick()
        // UI 开了插帧/要清晰画面时发全分辨率帧，否则发 480 宽缩略帧（省带宽）
        var full: CVPixelBuffer? = nil
        if EngineGlobals.wantFullFrame {
            EngineGlobals.latestFullFrameLock.lock()
            full = EngineGlobals.latestFullFrame
            EngineGlobals.latestFullFrameLock.unlock()
        }
        EngineGlobals.shm?.publish(
            image: st.currentFrameCG,
            detections: st.yoloEngine.detections,
            fps: st.captureEngine.captureFPS > 0 ? st.captureEngine.captureFPS : st.fps,
            isDriving: st.isDriving,
            isStreaming: st.isStreaming,
            fullFrame: full)
    }

    // MARK: - 命令处理

    static func handleCommand(_ line: String, server: EngineSocketServer) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            engineLog("[ENGINE] 无法解析命令: \(line)")
            return
        }
        engineLog("[ENGINE] 收到命令: \(type)")
        switch type {
        case "start":
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    EngineGlobals.clientSaidBye = false
                    EngineGlobals.state?.startDriving()
                    engineLog("[ENGINE] startDriving → isDriving=\(EngineGlobals.state?.isDriving ?? false)")
                }
            }
        case "stop":
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    EngineGlobals.state?.stopDriving()
                    engineLog("[ENGINE] stopDriving 完成（按键已释放）")
                }
            }
        case "bye":
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    EngineGlobals.clientSaidBye = true
                    EngineMain.pauseDriving("bye")
                }
            }
        case "status":
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    EngineMain.sendHeartbeat(reason: "status-query")
                }
            }
        case "upscale":
            // UI 开关「插帧/超分」→ 引擎据此决定发全分辨率帧还是 480 宽缩略帧
            let on = (obj["on"] as? Bool) ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    EngineGlobals.wantFullFrame = on
                    engineLog("[ENGINE] 画面档位切换：\(on ? "全分辨率（插帧/清晰）" : "480 宽缩略（省带宽）")")
                }
            }
        case "record":
            // UI 开关「行驶录制」→ 引擎执行真正的写盘。
            // 帧只存在于引擎进程（引擎模式下 UI 没有画面流），所以录制必须落在引擎侧。
            // 早先只在 UI 侧 recordEngine.start() 建了目录/文件，但 UI 的 tick 在引擎模式下
            // 提前 return，recordFrameIfNeeded() 永远不执行 → 目录建了、文件建了、录不进东西。
            let recOn = (obj["on"] as? Bool) ?? false
            let recGlyph = (obj["glyph"] as? Bool) ?? false
            let recExpert = (obj["expert"] as? Bool) ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let st = EngineGlobals.state else { return }
                    st.glyphMode = recGlyph
                    st.expertMode = recExpert
                    st.isRecording = recOn
                    let dir = st.recordEngine.sessionURL?.lastPathComponent ?? "-"
                    engineLog("[ENGINE] 录制\(recOn ? "开始" : "停止")：字模=\(recGlyph) 专家=\(recExpert) 会话=\(dir)")
                    // 立即回执：心跳周期 1s，不即时上报的话 UI 会先看到「还没录」，
                    // 把开关弹回去（UI 侧也有宽限期，这里是双保险）。
                    EngineMain.sendHeartbeat(reason: "record-ack")
                }
            }
        case "reloadmodel":
            // 训练完成后热替换模型：模型由 UI 侧的 Python 训练产出并落盘，
            // 但真正开车的推理引擎在引擎进程里。不转发这条命令，
            // 引擎会一直用内存里的旧模型 →「训练完了但车还按老模型开」。
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let st = EngineGlobals.state else { return }
                    st.inferenceEngine.reloadModel()
                    st.assistEngine.reloadModel()
                    st.yoloEngine.reloadModel()
                    engineLog("[ENGINE] 模型热替换：主驾/副驾/YOLO 三引擎已置空，下次推理重读磁盘")
                }
            }
        case "config":
            // UI 侧的「驾驶参数」同步。这些参数只在 tick() 里被读，而引擎模式下
            // tick() 只在引擎进程执行 —— 不推过来，UI 拨开关等于没拨。其中
            // controlDisabled（禁用控制）与 forceRuleMode（紧急切纯规则）是安全开关，
            // 不同步会让人以为车已经停手 / 已切安全档，实际还在跑模型。
            let cSport = obj["sport"] as? Bool
            let cCtrlDisabled = obj["controlDisabled"] as? Bool
            let cForceRule = obj["forceRule"] as? Bool
            let cExpert = obj["expert"] as? Bool
            let cGlyph = obj["glyph"] as? Bool
            let cThresh = obj["degradeThreshold"] as? Double
            let cSpeedLimit = obj["speedLimit"] as? Double
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let st = EngineGlobals.state else { return }
                    if let v = cSport { st.sportMode = v }
                    if let v = cCtrlDisabled { st.controlDisabled = v }
                    if let v = cForceRule { st.forceRuleMode = v }
                    if let v = cExpert { st.expertMode = v }
                    if let v = cGlyph { st.glyphMode = v }
                    if let v = cThresh { st.degradeThreshold = v }
                    // speedLimit 不是「显示项」：它经 InferenceEngine 变成
                    // vehicle_state[4] = speed_limit_norm 直接参与推理，不同步会
                    // 让 UI 显示 40 而模型仍按 120 决策。
                    if let v = cSpeedLimit { st.speedLimit = v }
                }
            }
        case "ping":
            server.send("{\"type\":\"pong\"}")
        default:
            engineLog("[ENGINE] 未知命令类型: \(type)")
        }
    }

    // MARK: - 心跳

    @MainActor
    static func sendHeartbeat(reason: String) {
        guard let st = EngineGlobals.state else { return }
        let detCount = st.yoloEngine.detections.count
        let fps = st.captureEngine.captureFPS > 0 ? st.captureEngine.captureFPS : st.fps
        let json = """
        {"type":"heartbeat","proto":\(EngineClient.protocolVersion),"ts":\(Int(Date().timeIntervalSince1970)),"fps":\(String(format: "%.1f", fps)),"detections":\(detCount),"isDriving":\(st.isDriving),"isStreaming":\(st.isStreaming),"mode":"\(st.mode)","modeRaw":"\(st.mode.rawValue)","speed":\(String(format: "%.1f", st.effectiveSpeed)),"speedKmh":\(String(format: "%.1f", st.speedKmh)),"confidence":\(String(format: "%.3f", st.confidence)),"recording":\(st.isRecording),"frames":\(st.recordEngine.frameCount),"pid":\(getpid()),"reason":"\(reason)"}
        """
        EngineGlobals.socket?.send(json)
    }

    // MARK: - 看门狗（UI 异常断开）

    @MainActor
    static func startReconnectWindow() {
        cancelReconnectWindow()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                if EngineGlobals.socket?.hasClient == true { return }   // 已重连
                engineLog("[ENGINE] 重连窗口超时：UI died, parking")
                EngineMain.pauseDriving("watchdog")
            }
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    @MainActor
    static func cancelReconnectWindow() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    // MARK: - 无人使用自动退出（UI 离开 30 秒无重连）

    /// UI 断开后启动倒计时：30 秒内无重连 → 自动安全退出（先 releaseAll）。
    /// 说明：引擎本身是「常驻」设计（UI 关掉也能继续驾驶），但没人用还一直占资源不合理，
    /// 所以加这道兜底。重连即取消（onClientConnected 里 cancel）。
    @MainActor
    static func startIdleExitCountdown() {
        cancelIdleExitCountdown()
        engineLog("[ENGINE] UI 已离开：30 秒内若无人重连，引擎将自动退出")
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                if EngineGlobals.socket?.hasClient == true { return }   // 已重连
                engineLog("[ENGINE] 30 秒无人使用，自动退出（先释放全部按键）")
                EngineMain.performShutdown(reason: "idle-exit")
            }
        }
        idleExitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: work)
    }

    @MainActor
    static func cancelIdleExitCountdown() {
        idleExitWorkItem?.cancel()
        idleExitWorkItem = nil
    }

    /// 暂停驾驶（安全侧）：立即释放全部按键，但保持抓屏与推理运行，等待 UI 重连。
    /// 用于：UI 主动 bye、看门狗超时。与 stop（显式停止、连抓屏一起停）区分。
    @MainActor
    static func pauseDriving(_ reason: String) {
        guard let st = EngineGlobals.state else { return }
        st.isDriving = false
        st.controlEngine.releaseAll()
        // UI 已离开（bye / 看门狗超时）：一并停掉录制。
        // 否则引擎会在无人监管下继续录 30 秒「车已停、标签还是上一刻 AI 决策」的垃圾帧，
        // 这些帧会被下次训练当成有效样本 → 污染模仿学习数据集。
        if st.isRecording {
            st.isRecording = false
            engineLog("[ENGINE] \(reason)：录制已停止（会话收尾并写 meta.json）")
        }
        engineLog("[ENGINE] \(reason)：已释放全部按键（抓屏与推理保持运行，等待 UI 重连）")
    }

    // MARK: - 退出（任何路径都先 releaseAll）

    @MainActor
    static func performShutdown(reason: String) {
        if let st = EngineGlobals.state {
            engineLog("[ENGINE] 退出流程（\(reason)）：释放全部按键")
            st.stopDriving()   // 内部含 controlEngine.releaseAll()
            // stop() 里的 meta.json 是 writeQueue.async 写的，紧接着 exit(0)
            // 会在元信息落盘前杀掉进程 → 录制会话缺 meta.json。这里等队列排空。
            st.recordEngine.flushSync()
        } else {
            // 状态尚未建立：兜底直接用 ControlEngine 释放
            ControlEngine().releaseAll()
        }
        EngineGlobals.socket?.stop()
        engineLog("[ENGINE] 退出完成")
        exit(0)
    }
}
