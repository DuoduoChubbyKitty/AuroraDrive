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
//
//  ⚠️ YOLOPX 在引擎模式下的行为（2026-09-26 核实，勿误判为"白烧算力"）：
//     **引擎模式下 YOLOPX 根本不跑。** 依据（代码事实，非推测）：
//       · `DriveState.tick()` 在 `EngineClient.shared.isActive` 时执行
//         `tickEngineMode(); return` —— **提前返回**（AuroraDriveApp.swift:3172 附近）；
//       · `yolopxEngine.infer(image:)` 全仓库仅 **1 处**调用，位于该 return **之后**
//         的本地推理分支（同文件 :3260）→ 引擎模式永远走不到。
//     结论：引擎模式既不会白烧 YOLOPX 算力，也因此**拿不到 da/ll 掩码** ——
//     掩码仅在 UI 侧本地推理时产生，共享内存协议里没有 da/ll 字段。
//     副作用提醒：引擎模式下 `MaskOverlay` 读到的是空掩码（不绘制），
//     而 `yolopxEngine.isDegraded` 保持初值 true → `LaneFallback` 不介入。
//     这属于**既定设计**（引擎模式的决策全部来自引擎回传），不是缺陷；
//     但若将来要在引擎模式下也显示掩码，必须先把 160×160 网格（约 50KB）
//     加进共享内存协议并在 tickEngineMode 回填 —— 目前**未做**。
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
///   80   maskSeq u64          (掩码世代号：变化才重发，UI 据此判断新鲜度)
///   88   maskW u32           (可行驶区网格宽)
///   92   maskH u32           (可行驶区网格高)
///   96   laneW u32           (车道线网格宽)
///   100  laneH u32           (车道线网格高)
///   104  maskFlags u32       (bit0 isDegraded / bit1 掩码有效)
///   108  maskRatio f32       (letterbox ratio，还原几何用)
///   112  maskPadX u32
///   116  maskPadY u32
///   120  maskSrcW u32
///   124  maskSrcH u32
///   128  maskNewW u32        (letterbox 后内容区宽，2026-09-28 补)
///   132  maskNewH u32        (letterbox 后内容区高，2026-09-28 补)
///
///        ⚠️ 2026-09-28：128/132 是**补传**的字段，不是新增功能。
///        起因：`MaskOverlay` 的绘制守卫原来写的是
///              `guard active, metrics.newW > 0, metrics.srcW > 0`
///        但协议头**从来没传过 newW/newH**，`EngineClient` 重建 `LetterboxMetrics`
///        时只能硬填 `newW: 0` → 守卫恒假 → 引擎模式下掩码一格都不画。
///        用户现象：「只能看到检测框，看不到可行驶区域和车道线」。
///        本机验证：本地模式正常（走 yolopxEngine.metrics，newW 是真实值），
///        所以本地自检永远发现不了 —— 这个 bug 只在引擎模式暴露。
///
///        修法有两步，两步都做了：
///          ① 把 newW/newH 真正写进协议（本处），让客户端能拿到真实值；
///          ② 同时去掉 `MaskOverlay` 里对 newW 的守卫依赖 —— 因为绘制数学
///             从头到尾没用过它（只用 ratio/padX/padY/srcW/srcH），
///             它本就不该是"能不能画"的判据。
///        ② 是必须的：只做①的话，旧引擎客户端仍会被卡住；
///        ① 也做是因为 newW/newH 是 letterbox 的完整描述，将来别处要用。
///
///        128/132 位于原本空闲的头部区（headerSize=4096，仅用到 125 字节），
///        不移动任何既有字段 → **对旧客户端向后兼容**（旧客户端不读这两格）。
/// 4096   检测结果区：detCapacity×detStride（每条：labelId u32 / conf f32 /
///        cx f32 / cy f32 / w f32 / h f32 / rawName 16 bytes / 预留）
/// 20480  像素页 A
/// 20480+pageSize  像素页 B
///
/// ⚠️ 掩码（可行驶区 da / 车道线 ll）的传输（2026-09-27 新增）
///
///   背景：此前引擎模式**根本不跑 YOLOPX**（见文件头注释），共享内存协议里
///   也没有 da/ll 字段 → UI 侧 `MaskOverlay` 永远读到空掩码，预览框里
///   看不到可行驶区和车道线。用户明确要求「引擎把掩码回传，UI 直接画」。
///
///   实现：把两个 160×160 的 0/1 网格 bit-pack 成位图（每行 20 字节），
///   放在检测区之后的 **maskOffset**。为什么 bit-pack 而不是直接发 UInt8：
///   160×160 = 25600 字节/掩码，两份 50KB，30Hz 下就是 1.5MB/s 的无谓拷贝；
///   bit-pack 后每份 3200 字节，两份 6.4KB，可忽略。
///
///   为什么用**世代号**而不是每帧无条件重发：掩码只在 YOLOPX 出结果的帧更新，
///   而 YOLOPX 是 15Hz、tick 是 30Hz。无条件重发会让一半的帧在传重复数据。
///   `maskSeq` 变化即重发，UI 侧读到新 seq 才解析。
final class EngineFrameShm {

    static let name = "/aurora_frame_v1"
    static let headerSize = 4096
    static let detOffset = 4096
    static let detCapacity = 256
    static let detStride = 64
    /// 检测区结束位置（= 4096 + 256×64 = 20480）
    static let detEnd = detOffset + detCapacity * detStride
    /// 掩码区：紧随检测区之后。
    ///
    /// ⚠️ 布局变更记录：旧版 `pixelsOffset` 直接等于 20480（检测区末尾），
    ///    没有给掩码留位置。新增掩码后必须把像素区往后挪，并把协议 version
    ///    升到 2 —— 否则新旧二进制混跑时 UI 会把掩码区当像素读（花屏）。
    ///    引擎与 UI 同源编译，不会出现长期混跑，但 version 仍要升：
    ///    引擎是**常驻后台进程**，UI 更新后引擎可能还是旧的（需重启引擎）。
    static let maskOffset = detEnd                                  // 20480
    static let maskGridMax = 160
    /// 单个掩码的位压缩字节数（160 行 × 每行 20 字节）
    static let maskBytes = maskGridMax * ((maskGridMax + 7) / 8)     // 3200
    /// 掩码区总容量：可行驶区 + 车道线
    static let maskRegionBytes = maskBytes * 2                       // 6400
    /// 像素区起始（掩码区之后，4KB 对齐）
    static let pixelsOffset = ((maskOffset + maskRegionBytes) + 4095) / 4096 * 4096  // 28672
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
    private func storeF32(_ off: Int, _ v: Float) {
        base.storeBytes(of: v, toByteOffset: off, as: Float.self)
    }

    /// 把 `MaskGrid` 位压缩写进共享内存。
    ///
    /// 为什么位压缩：160×160 用 UInt8 存是 25600 字节/份，两份 50KB；
    /// 位压缩后每步 20 字节/行 × 160 行 = 3200 字节，两份 6.4KB。
    /// 30Hz 下的差别是 1.5MB/s vs 192KB/s，而掩码本来只有 0/1 信息，
    /// 一个 bit 就够。
    ///
    /// - Parameters:
    ///   - grid: 要写的网格
    ///   - offset: 共享内存内的写入起始位置
    private func writeMask(_ grid: MaskGrid, offset: Int) {
        guard grid.width > 0, grid.height > 0 else { return }
        let rows = min(grid.height, EngineFrameShm.maskGridMax)
        let bytesPerRow = (min(grid.width, EngineFrameShm.maskGridMax) + 7) / 8
        let ptr = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        // 先清零（本次写的区域），避免上一帧的残留位被读成前景
        for i in 0..<(rows * bytesPerRow) { ptr[i] = 0 }
        for y in 0..<rows {
            let rowBase = y * bytesPerRow
            for x in 0..<min(grid.width, EngineFrameShm.maskGridMax) where grid.at(x, y) {
                ptr[rowBase + x / 8] |= UInt8(1 << (x % 8))
            }
        }
    }

    /// 发布掩码（可行驶区 + 车道线 + letterbox 几何）。
    ///
    /// 由 `EngineMain.publishTick` 在每 tick 调用；只有在掩码世代号变化时才
    /// 真正重写数据（见 publish 的 seq 判据），避免 30Hz 重发 15Hz 的数据。
    ///
    /// - Parameter seq: 掩码世代号。YOLOPX 出结果时 +1，UI 侧据此判断新鲜度。
    func publishMasks(drivable: MaskGrid, lane: MaskGrid,
                      metrics: LetterboxMetrics, isDegraded: Bool,
                      laneDegraded: Bool, drivableDegraded: Bool, seq: UInt64) {
        storeU64(80, seq)
        storeU32(88, UInt32(drivable.width))
        storeU32(92, UInt32(drivable.height))
        storeU32(96, UInt32(lane.width))
        storeU32(100, UInt32(lane.height))
        // bit0 = 总降级；bit1 = 掩码是否有效（有数据）
        // bit2 = 车道线单独塌陷；bit3 = 可行驶区单独塌陷
        //
        // bit2/bit3 是 2026-09-27 加的：原先 UI 只有一个总降级位，
        // 无法区分"是车道线塌了还是可行驶区塌了"，于是显示层只能一刀切压暗，
        // 造成车道线塌陷把可行驶区一起带暗（用户报"什么都看不到"的直接原因）。
        var flags: UInt32 = 0
        if isDegraded { flags |= 1 }
        if drivable.width > 0 || lane.width > 0 { flags |= 2 }
        if laneDegraded { flags |= 4 }
        if drivableDegraded { flags |= 8 }
        storeU32(104, flags)
        storeF32(108, Float(metrics.ratio))
        storeU32(112, UInt32(metrics.padX))
        storeU32(116, UInt32(metrics.padY))
        storeU32(120, UInt32(metrics.srcW))
        storeU32(124, UInt32(metrics.srcH))
        // 128/132：letterbox 内容区尺寸（2026-09-28 补传，原为客户端硬填 0）
        storeU32(128, UInt32(metrics.newW))
        storeU32(132, UInt32(metrics.newH))

        writeMask(drivable, offset: EngineFrameShm.maskOffset)
        writeMask(lane, offset: EngineFrameShm.maskOffset + EngineFrameShm.maskBytes)
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

    /// 掩码世代号。YOLOPX 每次产出新掩码时 +1，UI 侧据此判断是否要重新解析。
    ///
    /// 为什么需要：YOLOPX 是 15Hz 而 tick 是 30Hz，掩码在两次更新之间不变。
    /// 无条件重发会让一半的帧在传重复数据；UI 侧每帧展开位图也纯属浪费。
    @MainActor static var maskSeq: UInt64 = 0
    /// 上一次发布时的掩码指纹（用于判断"掩码是否真的变了"）
    @MainActor static var lastMaskFingerprint: Int = 0
}

// MARK: - 引擎主入口

enum EngineMain {

    static func run() -> Never {
        // ⚠️ 2026-10-10 修复「引擎进程 print 不落盘」：
        //   引擎进程的 stdout 被 UI 重定向到 ~/Library/Logs/AuroraEngine.log。
        //   重定向到文件时 stdio 默认是**块缓冲**（4KB 才 flush）→ 引擎里所有
        //   `print("[cap-deep] ...")` 全卡在内存缓冲区，日志里一个字都看不到
        //   （诊断时误判成"代码没走到"）。UI 启动路径早在 AuroraDriveApp.swift:751
        //   设了行缓冲，引擎路径漏了 —— 这里补齐。
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)
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
        // A17 迁移：环境开关统一走 `AuroraFlags`（进程内只读一次，不在热路径现读）
        let diagSkip = AuroraFlags.engineDiagSkipTCC
        engineLog("[ENGINE] TCC 自检 ax=\(axOK) screen=\(screenOK)")
        // ══════════════════════════════════════════════════════════════════════
        // ⚠️ 2026-09-30：观测模式（AURORA_OBSERVE_ONLY=1）下放宽辅助功能要求
        // ══════════════════════════════════════════════════════════════════════
        //
        // 【为什么】原来的判据是 `!(axOK && screenOK)` —— **两项都必须在**。
        //   这个判据对「引擎要注入按键」的用途是对的，但对**观测用途过严**：
        //
        //     · 辅助功能权限（ax）的用途是 **CGEvent 按键注入**
        //     · 屏幕录制权限（screen）的用途是 **抓帧给推理用**
        //
        //   而观测模式跑的正是「只看不碰」这条路：
        //   它由 `AURORA_OBSERVE_ONLY=1` 强制 `controlDisabled = true`
        //   （见 AuroraDriveApp.swift `startDriving()` 的说明），
        //   **一行按键都不会注入** —— 于是 ax 权限对它毫无用处。
        //   真正必需的只有 screen：没有帧，推理就没有输入，观测也就无从谈起。
        //
        // 【修法】观测模式下把判据收窄为「必须有 screen」。
        //   注意**没有**放宽 screen 要求 —— 观测模式恰恰最需要它。
        //
        // 【安全边界】这不是「跳过权限检查」：
        //   · 非观测模式（默认）判据**逐字不变**，仍是 `axOK && screenOK`。
        //   · 观测模式下 ax 被允许为 false，但该模式下注入路径已被
        //     `controlDisabled=true` 关闭（两条 gate + `ControlEngine.hold()`
        //     自身的第三层权限 gate，详见文档 6.23.3 的逐行审计）。
        //   · 即便真的尝试注入，`hold()` 的 `guard hasAccessibilityPermission`
        //     也会提前 return —— 权限不足时物理上注入不出去。
        let observeOnly = AuroraFlags.observeOnly
        let tccSatisfied = observeOnly ? screenOK : (axOK && screenOK)
        if !tccSatisfied {
            if diagSkip {
                engineLog("[ENGINE] ⚠️ 诊断旁路生效（AURORA_ENGINE_DIAG_SKIP_TCC=1），继续运行以便验证非权限逻辑")
            } else if observeOnly {
                // 观测模式下只差 screen 时，给出精确的缺失项（便于用户定位该勾哪个）
                engineLog("[ENGINE] 观测模式：屏幕录制权限缺失（ax=\(axOK) 观测模式不需要）→ fail-fast")
                exit(2)
            } else {
                engineLog("[ENGINE] TCC 权限不足，fail-fast 退出（权限须由父进程链继承）")
                exit(2)
            }
        } else if observeOnly && !axOK {
            engineLog("[ENGINE] 观测模式（AURORA_OBSERVE_ONLY=1）：screen=\(screenOK) 通过，"
                      + "ax=\(axOK) 按设计放宽（本模式不注入按键）")
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
            if AuroraFlags.engineDiagCaptureOnly {
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
                        // 掩码诊断：把「引擎到底有没有在跑 YOLOPX、有没有把掩码发出去」
                        // 变成日志里可见的事实。
                        //
                        // 为什么必须加这段：此前 `引擎模式下 YOLOPX 到底跑不跑`
                        // 只存在于代码注释的推断里（EngineMain.swift 顶部那段
                        // 「根本不跑」），而它是**基于旧代码**写的 —— 那时
                        // yolopxEngine.infer 只在 UI 本地分支调用。后来引擎也跑
                        // 同一个 tick，结论可能已经反转，但没有任何运行时证据。
                        // 用户报「看不到车道线」时，无法区分是
                        // ①模型没输出 ②引擎没跑 ③掩码没传 ④UI 没画。
                        // 这行把 ① ② ③ 一次性暴露出来（④ 由 UI 侧自理）。
                        let px = EngineGlobals.state?.yolopxEngine
                        engineLog("[ENGINE] 统计: seq=\(seq) 有帧=\(hasFrame) det=\(EngineGlobals.state?.yoloEngine.detections.count ?? 0) driving=\(EngineGlobals.state?.isDriving ?? false)"
                            + " yolopx:加载=\(px?.isLoaded ?? false) 帧数=\(px?.inferenceCount ?? 0)"
                            + " da=\(px?.drivableMask.positiveCount ?? 0)格 ll=\(px?.laneMask.positiveCount ?? 0)格"
                            + " 降级=\(px?.isDegraded ?? true) maskSeq=\(EngineGlobals.maskSeq)"
                            // ── 2026-09-29 新增：YOLOPX 单帧耗时（此前只在 selftest 打印，
                            //    真机路径完全没有记录，导致「真机 385ms vs 空载 50ms」
                            //    这个 7.7 倍差距无从追溯）。lastLatencyMs 覆盖
                            //    「模型推理 + NMS + 掩码提取」，不含主线程 letterbox。
                            + " 耗时=\(String(format: "%.1f", px?.lastLatencyMs ?? 0))ms")

                        // ── 阶段1（2026-10-01）：生产 tick 分段统计导出 ──
                        // 【为什么在这里导出】`PerfBus` 是**进程内**单例，而生产 tick
                        //   跑在引擎进程里 —— 从外部另起一个 `--tick-profile` 进程读不到
                        //   任何样本（实测确实读到全 0，这本身就印证了"盲区"的存在）。
                        //   故复用本已存在的 5 秒统计通道把分段数据写进日志，
                        //   这样**不需要任何新机制**就能在真实负载下取到分段占比。
                        //
                        // 【零成本】仅在 `AURORA_PERF=1` 时输出；未设时下面整段跳过，
                        //   连字符串拼接都不会发生。
                        if PerfBus.enabled {
                            let seg = ["tick.consumeFrame", "tick.yoloFast", "tick.opticalflow",
                                       "tick.nativeROI", "tick.motion", "tick.speed",
                                       "tick.degrade", "tick.confidence", "tick.ruleDecision",
                                       "tick.laneFallback", "tick.inject", "tick.record",
                                       "tick.debugSummary", "tick.total"]
                            var parts: [String] = []
                            for ch in seg {
                                let st = PerfBus.shared.stats(ch)
                                guard !st.isEmpty else { continue }
                                // 只报 p50/p95：n 与 mean 在日志里冗余（卡顿看长尾）
                                let name = ch.replacingOccurrences(of: "tick.", with: "")
                                parts.append(String(format: "%@=%.2f/%.2f", name, st.median, st.p95))
                            }
                            if !parts.isEmpty {
                                // 采样窗口后 reset，让下一条统计反映**新窗口**而非累计值 ——
                                // 累计值会被进程启动初期的懒加载/预热污染（上一轮 n=1 踩过）。
                                engineLog("[PERF] tick分段(p50/p95 ms): " + parts.joined(separator: " "))
                                PerfBus.shared.reset()
                            }
                        }
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

        // ── 掩码回传（协议 v3）──
        //
        // 为什么在这里而不是在 publish 内部：publish 是"帧发布"，掩码是另一条
        // 数据流（不同更新频率）。分开调用语义更清楚，也便于单独短路。
        //
        // 为什么用指纹短路：YOLOPX 15Hz / tick 30Hz，连续两帧的掩码通常一模一样。
        // 指纹 = 前景格数 + 尺寸（前景格数变化即认为掩码变了；这个判据足够灵敏，
        // 因为掩码是 0/1 网格，格数不变而形状变的概率极低，且即使漏一次
        // 也只影响一帧的显示，下一帧必然补上）。
        //
        // ⚠️ 只在驾驶中发：没开始驾驶时引擎本来就没有掩码（模型未加载），
        //    发空网格等于让 UI 侧白跑一遍解析。
        if st.isDriving {
            let da = st.yolopxEngine.drivableMask
            let ll = st.yolopxEngine.laneMask
            let fp = da.positiveCount &* 1000003 &+ ll.positiveCount &* 31
                &+ da.width &* 7 &+ ll.width
            if fp != EngineGlobals.lastMaskFingerprint {
                EngineGlobals.lastMaskFingerprint = fp
                EngineGlobals.maskSeq &+= 1
            }
            EngineGlobals.shm?.publishMasks(
                drivable: da, lane: ll,
                metrics: st.yolopxEngine.metrics,
                isDegraded: st.yolopxEngine.isDegraded,
                laneDegraded: st.yolopxEngine.laneDegraded,
                drivableDegraded: st.yolopxEngine.drivableDegraded,
                seq: EngineGlobals.maskSeq)
        } else if EngineGlobals.maskSeq != 0 {
            // 停车：清掉掩码，避免 UI 侧留着上一次驾驶的残影
            EngineGlobals.maskSeq = 0
            EngineGlobals.lastMaskFingerprint = 0
            EngineGlobals.shm?.publishMasks(drivable: .empty, lane: .empty,
                                            metrics: .zero, isDegraded: true,
                                            laneDegraded: true, drivableDegraded: true,
                                            seq: 0)
        }
    }

    // MARK: - 命令处理

    /// 把任意 JSON 标量转成字符串（用于 ack 的 id 原样回显）。
    ///
    /// 为什么不用 `as? String`：AI/脚本可能用数字做关联 id（`{"id": 7}`），
    /// 只认 String 会让 `{"id":7}` 被当成"没有 id"而静默不回执 —— 正是本任务要消除的
    /// "发完命令不知道成没成"。这里把 Int/Double/Bool/String 都转成 String，
    /// 回显时**原样**（数字 7 回 "7"，字符串 "a" 回 "a"）。
    private static func ackIDString(_ raw: Any?) -> String? {
        switch raw {
        case let s as String:  return s
        case let b as Bool:    return b ? "true" : "false"
        case let i as Int:     return String(i)
        case let d as Double:
            // 整数值的 Double（JSON 里 7 有时被解析成 7.0）回 "7" 而非 "7.0"，更贴近原样
            return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case let n as NSNumber: return n.stringValue
        default:               return nil
        }
    }

    /// 组装并发送一条 ack。
    ///
    /// 契约（task-A）：
    ///   `{"type":"ack","id":"<原样>","cmd":"<type>","ok":bool,"detail":"<人类可读>","data":{...}}`
    ///   · **只有入参带 id 时才发**（`id` 为 nil 时本函数直接 return）→ 向后兼容，
    ///     现有 UI 的 start/stop/config/set_capture_mode 调用点一个字节都不受影响。
    ///   · `data` 为空字典时省略该字段（保持行紧凑）。
    ///   · ok 语义：**真的执行了才 true**；参数非法/前置条件不满足 → false + detail 说明原因。
    ///     不许谎报成功。
    static func sendAck(id: String?, cmd: String, ok: Bool,
                        detail: String, data: [String: Any]? = nil,
                        server: EngineSocketServer) {
        guard let id else { return }        // ★ 无 id → 完全不回（向后兼容硬要求）
        var obj: [String: Any] = [
            "type": "ack",
            "id": id,
            "cmd": cmd,
            "ok": ok,
            "detail": detail,
        ]
        if let data, !data.isEmpty { obj["data"] = data }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: jsonData, encoding: .utf8) else {
            engineLog("[ENGINE] ⚠️ ack 序列化失败: cmd=\(cmd)")
            return
        }
        server.send(json)
    }

    /// 捕获模式切换的**唯一实现**（`set_capture_mode` 与 `capture` 共用，避免两份实现漂移）。
    ///
    /// 语义与改造前的 `set_capture_mode` **逐字一致**（含非法参数回落全屏的行为），
    /// 但把结果（成功/失败原因）通过 completion 交回，供 ack 如实上报。
    ///
    /// - Returns（经 completion）：`(实际生效模式, 错误原因或 nil)`
    ///   · 成功 → error 为 nil
    ///   · 窗口不存在 / 权限变化 → error 为 `captureEngine.lastModeError` 的原文
    @MainActor
    private static func performCaptureModeSwitch(modeStr: String, windowID: Int?) async
        -> (mode: CaptureMode, error: String?) {
        // 参数解析与改造前一致：mode=="window" 且有 windowID → 窗口模式，否则全屏
        let capMode: CaptureMode
        if modeStr == "window", let id = windowID {
            capMode = .window(id: CGWindowID(truncatingIfNeeded: id))
        } else {
            capMode = .fullScreen
        }
        guard let st = EngineGlobals.state else {
            return (capMode, "引擎状态未就绪（EngineGlobals.state == nil）")
        }
        await st.captureEngine.applyMode(capMode)
        // applyMode 无返回值：成功与否看它是否写入 lastModeError（见 CaptureEngine 注释：
        // 「失败处理：保持原模式不变，把原因写进 lastModeError」）。
        // ⚠️ 必须在 await 之后再读 —— applyMode 是 async，读早了拿不到本次结果。
        return (capMode, st.captureEngine.lastModeError)
    }

    /// 组装 `state` 查询的结构化结果。
    ///
    /// 【安全取值】引擎刚启动 / 模型未加载 / state 尚未建立时**都不能崩**：
    ///   · `EngineGlobals.state == nil` → 全部字段走默认值，并置 `ready=false`
    ///   · 每个可选量都用 `?.` + `?? 默认值`，不做强制解包
    /// 【单位】speedKmh / effectiveSpeed 为 km/h；confidence 为 0~1；trackMode 为 0/1 数值。
    @MainActor
    private static func buildStateSnapshot() -> [String: Any] {
        guard let st = EngineGlobals.state else {
            // 状态未建立：给一份"全默认"快照，字段名与正常路径**完全一致**
            // （AI 侧无需区分两种形状，缺的只是值）
            return [
                "ready": false,
                "driving": false,
                "isStreaming": false,
                "frames": 0,
                "publishedSeq": Int(EngineGlobals.shm?.publishedSeq ?? 0),
                "hasFrame": false,
                "fps": 0.0,
                "mode": "unknown",
                "speedKmh": 0.0,
                "effectiveSpeed": 0.0,
                "confidence": 0.0,
                "detections": 0,
                "captureMode": "unknown",
                "isCapturing": false,
                "desiredMode": "unknown",
                "lastModeError": NSNull(),
                "recording": false,
                "v2Loaded": false,
                "v2Split": false,
                "worldModel": false,
                "trackMode": 0.0,
                "yoloLoaded": false,
                "yolopxLoaded": false,
                "pid": Int(getpid()),
            ]
        }
        let fps = st.captureEngine.captureFPS > 0 ? st.captureEngine.captureFPS : st.fps
        let lastErr: Any = st.captureEngine.lastModeError ?? NSNull()
        return [
            "ready": true,
            "driving": st.isDriving,
            "isStreaming": st.isStreaming,
            "frames": st.recordEngine.frameCount,
            "publishedSeq": Int(EngineGlobals.shm?.publishedSeq ?? 0),
            "hasFrame": st.currentFrameCG != nil,
            "fps": fps,
            "mode": st.mode.rawValue,
            "speedKmh": st.speedKmh,
            "effectiveSpeed": st.effectiveSpeed,
            "confidence": st.confidence,
            "detections": st.yoloEngine.detections.count,
            "captureMode": st.captureEngine.captureMode.label,
            "isCapturing": st.captureEngine.isCapturing,
            "desiredMode": st.captureEngine.desiredMode.label,
            "lastModeError": lastErr,
            "recording": st.isRecording,
            "v2Loaded": st.inferenceEngineV2.isLoaded,
            "v2Split": st.inferenceEngineV2.useSplitModels,
            "worldModel": st.inferenceEngineV2.worldModelLoaded,
            "trackMode": Double(st.inferenceEngineV2.trackModeValue),
            "yoloLoaded": st.yoloEngine.isLoaded,
            "yolopxLoaded": st.yolopxEngine.isLoaded,
            "pid": Int(getpid()),
        ]
    }

    static func handleCommand(_ line: String, server: EngineSocketServer) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            engineLog("[ENGINE] 无法解析命令: \(line)")
            return
        }
        engineLog("[ENGINE] 收到命令: \(type)")
        // ★ task-A：关联 id（任意 JSON 标量 → String）。为 nil 时**所有 ack 都不发**，
        //   行为与改造前逐字一致（现有 UI 调用点不带 id）。
        let ackID = ackIDString(obj["id"])
        switch type {
        case "start":
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    EngineGlobals.clientSaidBye = false
                    EngineGlobals.state?.startDriving()
                    engineLog("[ENGINE] startDriving → isDriving=\(EngineGlobals.state?.isDriving ?? false)")
                    let driving = EngineGlobals.state?.isDriving ?? false
                    EngineMain.sendAck(
                        id: ackID, cmd: type, ok: driving,
                        detail: driving ? "已开始驾驶" : "start 已下发，但 isDriving 仍为 false（状态未就绪）",
                        data: ["driving": driving], server: server)
                }
            }
        case "stop":
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    EngineGlobals.state?.stopDriving()
                    engineLog("[ENGINE] stopDriving 完成（按键已释放）")
                    let driving = EngineGlobals.state?.isDriving ?? false
                    EngineMain.sendAck(
                        id: ackID, cmd: type, ok: !driving,
                        detail: driving ? "stop 已下发，但 isDriving 仍为 true" : "已停止驾驶（按键已释放）",
                        data: ["driving": driving], server: server)
                }
            }
        case "bye":
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    EngineGlobals.clientSaidBye = true
                    EngineMain.pauseDriving("bye")
                    EngineMain.sendAck(
                        id: ackID, cmd: type, ok: true,
                        detail: "已接收 bye：暂停驾驶并释放全部按键",
                        data: ["driving": EngineGlobals.state?.isDriving ?? false], server: server)
                }
            }
        case "status":
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    EngineMain.sendHeartbeat(reason: "status-query")
                    // status 的 ack 直接带完整快照（AI 一次调用就能拿到全部状态）
                    EngineMain.sendAck(
                        id: ackID, cmd: type, ok: true,
                        detail: "已回发心跳 + 状态快照",
                        data: EngineMain.buildStateSnapshot(), server: server)
                }
            }
        case "upscale":
            // UI 开关「插帧/超分」→ 引擎据此决定发全分辨率帧还是 480 宽缩略帧
            let on = (obj["on"] as? Bool) ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    EngineGlobals.wantFullFrame = on
                    engineLog("[ENGINE] 画面档位切换：\(on ? "全分辨率（插帧/清晰）" : "480 宽缩略（省带宽）")")
                    EngineMain.sendAck(
                        id: ackID, cmd: type, ok: true,
                        detail: on ? "已切到全分辨率帧" : "已切到 480 宽缩略帧",
                        data: ["wantFullFrame": on], server: server)
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
            // 2026-10-08：录制视角随命令从 UI 下发（"first"/"third"）。
            //
            // 【为什么必须在这里读】引擎模式是**默认路径**（UI 启动即 spawn `--engine`），
            // 真正写盘的是**引擎进程**的 RecordEngine。UI 侧 DriveState.recordThirdPerson
            // 只存在于 UI 进程 —— 不把视角传过来，用户在 UI 选了第三视角、引擎照旧录
            // 第一人称，而且**不报任何错**（静默不一致：看着对、实际错）。
            //
            // 【防御】老版 UI 不发这个字段 → 缺省 "first"，行为与改造前完全一致。
            // 归一化复用 RecordEngine.normalizePerspective（非法值回落 first，
            // 不因一个字符串拼错就让整场录制失败）。
            let recPerspective = RecordEngine.normalizePerspective(
                (obj["perspective"] as? String) ?? "first")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let st = EngineGlobals.state else {
                        EngineMain.sendAck(id: ackID, cmd: type, ok: false,
                                           detail: "引擎状态未就绪（EngineGlobals.state == nil）",
                                           server: server)
                        return
                    }
                    st.glyphMode = recGlyph
                    st.expertMode = recExpert
                    // 同步视角到引擎侧 DriveState：`isRecording` 的 didSet 也会读
                    // `recordPerspective` 去 start()，不同步的话那条路径会用默认 first。
                    // 这里先写，保证「显式 start」与「didSet 兜底」两条路拿到同一视角。
                    st.recordThirdPerson = (recPerspective == "third")
                    // 先 start/stop 再置 isRecording：start() 才会建目录、写 view.txt，
                    // 顺序反了会出现「开关已开、目录还没建」的空窗（心跳上报 session="-"）。
                    if recOn, !st.recordEngine.isRecording {
                        st.recordEngine.glyphMode = recGlyph
                        st.recordEngine.start(perspective: recPerspective)
                    } else if !recOn, st.recordEngine.isRecording {
                        st.recordEngine.stop()
                    }
                    st.isRecording = recOn
                    let dir = st.recordEngine.sessionURL?.lastPathComponent ?? "-"
                    let viewLabel = recPerspective == "third" ? "TPV" : "FPV"
                    engineLog("[ENGINE] 录制\(recOn ? "开始" : "停止")：字模=\(recGlyph) 专家=\(recExpert) "
                              + "视角=\(recPerspective)(\(viewLabel)) 会话=\(dir)")
                    // 立即回执：心跳周期 1s，不即时上报的话 UI 会先看到「还没录」，
                    // 把开关弹回去（UI 侧也有宽限期，这里是双保险）。
                    EngineMain.sendHeartbeat(reason: "record-ack")
                    // ok 以"实际是否处于请求的状态"为准，不谎报
                    EngineMain.sendAck(
                        id: ackID, cmd: type, ok: st.isRecording == recOn,
                        detail: "录制\(recOn ? "开始" : "停止")：视角=\(recPerspective)(\(viewLabel)) 会话=\(dir)",
                        data: ["recording": st.isRecording, "frames": st.recordEngine.frameCount,
                               "session": dir, "perspective": recPerspective],
                        server: server)
                }
            }
        case "reloadmodel":
            // 训练完成后热替换模型：模型由 UI 侧的 Python 训练产出并落盘，
            // 但真正开车的推理引擎在引擎进程里。不转发这条命令，
            // 引擎会一直用内存里的旧模型 →「训练完了但车还按老模型开」。
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let st = EngineGlobals.state else {
                        EngineMain.sendAck(id: ackID, cmd: type, ok: false,
                                           detail: "引擎状态未就绪（EngineGlobals.state == nil）",
                                           server: server)
                        return
                    }
                    st.inferenceEngine.reloadModel()
                    st.assistEngine.reloadModel()
                    st.yoloEngine.reloadModel()
                    engineLog("[ENGINE] 模型热替换：主驾/副驾/YOLO 三引擎已置空，下次推理重读磁盘")
                    // 语义说明：本命令只"置空待重载"，真正读盘发生在下一次推理。
                    // 因此 ok=true 表示"已受理"，detail 写清"下次推理时生效"，不谎称"已加载新模型"。
                    EngineMain.sendAck(
                        id: ackID, cmd: type, ok: true,
                        detail: "已置空主驾/副驾/YOLO 三引擎，下次推理时重读磁盘（本命令不阻塞等加载）",
                        server: server)
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
            // 消化模式：真正注入按键的是**引擎进程**，UI 侧开关必须下发到这里，
            //   否则「UI 显示已消化、引擎照旧真按键」—— 那是最危险的不一致。
            let cDigest = obj["digest"] as? Bool
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let st = EngineGlobals.state else {
                        EngineMain.sendAck(id: ackID, cmd: type, ok: false,
                                           detail: "引擎状态未就绪（EngineGlobals.state == nil）",
                                           server: server)
                        return
                    }
                    if let v = cSport { st.sportMode = v }
                    if let v = cCtrlDisabled { st.controlDisabled = v }
                    if let v = cForceRule { st.forceRuleMode = v }
                    if let v = cExpert { st.expertMode = v }
                    if let v = cGlyph { st.glyphMode = v }
                    if let v = cThresh { st.degradeThreshold = v }
                    // 消化模式：同步到引擎的 ControlEngine（唯一真注入方）
                    if let v = cDigest, st.controlEngine.digestMode != v {
                        st.controlEngine.digestMode = v
                        engineLog("[ENGINE] 🧪 消化模式\(v ? " ON（不真发按键）" : " OFF（恢复真注入）")")
                    }
                    // speedLimit 不是「显示项」：它经 InferenceEngine 变成
                    // vehicle_state[4] = speed_limit_norm 直接参与推理，不同步会
                    // 让 UI 显示 40 而模型仍按 120 决策。
                    if let v = cSpeedLimit { st.speedLimit = v }
                    // 如实回显"本次真正写入了哪些键"（未传的键不写、也不虚报）
                    var applied: [String: Any] = [:]
                    if let v = cSport { applied["sport"] = v }
                    if let v = cCtrlDisabled { applied["controlDisabled"] = v }
                    if let v = cForceRule { applied["forceRule"] = v }
                    if let v = cExpert { applied["expert"] = v }
                    if let v = cGlyph { applied["glyph"] = v }
                    if let v = cThresh { applied["degradeThreshold"] = v }
                    if let v = cSpeedLimit { applied["speedLimit"] = v }
                    EngineMain.sendAck(
                        id: ackID, cmd: type, ok: true,
                        detail: applied.isEmpty ? "config 未包含任何可识别字段（无改动）"
                                                : "已同步 \(applied.count) 个参数",
                        data: ["applied": applied], server: server)
                }
            }
        case "set_capture_mode", "capture":
            // UI 预览框拉条点选「录全屏」或某个窗口 → 引擎执行真正的 filter 切换。
            // 引擎模式下 UI 的 captureEngine 是空壳（isCapturing=false），不转发就是
            // 「点了没反应」（用户原话）。
            //
            // ★ task-A：`capture` 是 `set_capture_mode` 的 AI 友好别名，语义**完全相同**，
            //   两者都走下面同一个 performCaptureModeSwitch（单一实现，避免漂移）。
            //   区别只在 ack：`capture` 明确回执切换结果（成功/失败原因）；
            //   `set_capture_mode` 沿用原行为，仅在带 id 时回执（不带 id 时零回包，
            //   现有 UI 调用点不受影响）。
            let modeStr = (obj["mode"] as? String) ?? "fullscreen"
            let wID = obj["windowID"] as? Int
            // 参数合法性（仅对显式声明的非法组合判 false，不改变原有回落行为）：
            //   mode=="window" 但没给 windowID → 原实现静默回落全屏；
            //   这里照旧回落，但 ack 如实说明"未收到 windowID，已回落全屏"。
            let windowModeMissingID = (modeStr == "window" && wID == nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // ⚠️ 必须写 `Task<Void, Never>`：在 assumeIsolated 闭包内裸 `Task { }`
                    //    同时匹配 `Task` 与 `Task<Void, Never>` 两个 init 重载 → 歧义编译错。
                    Task<Void, Never> {
                        let (capMode, err) = await EngineMain.performCaptureModeSwitch(
                            modeStr: modeStr, windowID: wID)
                        engineLog("[ENGINE] 捕获源切换（\(type)）：\(capMode.label)"
                                  + (err.map { " ⚠️ \($0)" } ?? " ✅"))
                        var data: [String: Any] = [
                            "mode": capMode.isWindowMode ? "window" : "fullscreen",
                            "captureMode": capMode.label,
                            "isCapturing": EngineGlobals.state?.captureEngine.isCapturing ?? false,
                        ]
                        if case .window(let id) = capMode { data["windowID"] = Int(id) }
                        let ok = (err == nil)
                        var detail: String
                        if let err {
                            detail = err
                        } else if windowModeMissingID {
                            detail = "mode=window 但未提供 windowID → 已按原语义回落全屏（\(capMode.label)）"
                        } else {
                            detail = "已切到 \(capMode.label)"
                        }
                        if let st = EngineGlobals.state, !st.captureEngine.isCapturing {
                            // 未在捕获时 applyMode 只记 desiredMode（早退），如实说明，
                            // 不让调用方以为"已经切换生效"
                            detail += "（当前未在捕获，已记录期望模式，start() 时生效）"
                        }
                        EngineMain.sendAck(id: ackID, cmd: type, ok: ok, detail: detail,
                                           data: data, server: server)
                    }
                }
            }
        case "state":
            // ★ task-A 新增：结构化状态查询（AI 友好）。
            // 走 ack 机制（带 id）；不带 id 时按契约**不回包**（与其它命令一致）。
            // 全部字段安全取值，引擎刚启动 / 模型未加载也不崩（见 buildStateSnapshot）。
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let snap = EngineMain.buildStateSnapshot()
                    let ready = (snap["ready"] as? Bool) ?? false
                    EngineMain.sendAck(
                        id: ackID, cmd: type, ok: true,
                        detail: ready ? "状态快照已生成" : "引擎状态尚未建立，返回全默认快照（ready=false）",
                        data: snap, server: server)
                }
            }
        case "ping":
            server.send("{\"type\":\"pong\"}")
            // ping 额外支持带 id 的 ack（pong 保持不变，向后兼容）
            EngineMain.sendAck(id: ackID, cmd: type, ok: true, detail: "pong",
                               server: server)
        default:
            engineLog("[ENGINE] 未知命令类型: \(type)")
            // 未知命令：带 id 时如实回 ok=false（AI 能立刻知道命令拼错了，
            // 而不是干等）；不带 id 时保持原样（仅打日志，零回包）。
            EngineMain.sendAck(id: ackID, cmd: type, ok: false,
                               detail: "未知命令类型：\(type)", server: server)
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
