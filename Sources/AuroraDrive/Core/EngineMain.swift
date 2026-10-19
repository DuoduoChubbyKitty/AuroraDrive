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
//   6) DriveState 闭环    —— 照搬主程序组装（同一份类代码）+ 20Hz DispatchSource tick
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
import ScreenCaptureKit   // validateWindowExists 枚举可捕获窗口用（P2 修复）

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
        let cols = min(grid.width, EngineFrameShm.maskGridMax)
        let bytesPerRow = (cols + 7) / 8
        let ptr = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        // 先清零（本次写的区域），避免上一帧的残留位被读成前景
        ptr.initialize(repeating: 0, count: rows * bytesPerRow)
        // ★ 2026-10-14 性能优化：连续数组位打包替代逐格 grid.at() RMW（16× 加速）。
        //   等价性要求（与原 at() 语义逐格对齐）：MaskGrid 是 struct，合成构造器不校验
        //   cells.count == width*height（见 YolopxEngine.swift 的 R2-H1 注释），原 at()
        //   对越界格返回 false（跳过），故这里也必须逐行按可用长度截断，不能整段 return。
        grid.cells.withUnsafeBufferPointer { buf in
            guard let src = buf.baseAddress else { return }
            let avail = buf.count
            for y in 0..<rows {
                let rowStart = y * grid.width
                if rowStart >= avail { break }                    // 该行整体越界 → 跳过（原 at 返回 false）
                let usable = min(cols, avail - rowStart)          // 该行实际可读的列数
                if usable <= 0 { break }
                let srow = src + rowStart
                let drow = ptr + y * bytesPerRow
                var x = 0
                while x + 8 <= usable {
                    var byte: UInt8 = 0
                    for k in 0..<8 where srow[x + k] != 0 { byte |= UInt8(1 << k) }
                    drow[x >> 3] = byte
                    x += 8
                }
                while x < usable { if srow[x] != 0 { drow[x >> 3] |= UInt8(1 << (x & 7)) }; x += 1 }
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

    /// 引擎主循环 tick 频率（Hz）。**全链路唯一真值**：推理 / 控制 / 录制三条路径
    /// 都挂在 `tickOnce()` 上，所以改这一个常量即三路生效。
    ///
    /// 【频率演进史 —— 按时间倒序，看最新的那节】
    ///
    /// ── 2026-10-12 最终定档（最新，以此为准）──
    ///   · **tick（推理+控制+录制）**：**20Hz**（两档都是，见 `tickHz(forPerceptionMode:)`）
    ///   · **抓屏（画面流）**：**20fps**（两档都是，见 `captureHz(forPerceptionMode:)`）
    ///     理由：45fps 时每 tick 只消费 1 帧，多余 25 帧被跳帧丢弃，纯浪费带宽/CPU；
    ///     所有消费者（推理/检测/预览/OCR）都是 tick 驱动，45 完全多余。
    ///   · **例外**：应急冲刺（sprint）时 tick 与抓屏一起提到 45Hz/45fps（见 `tickOnce`）。
    ///
    /// ── 历史：2026-10-11 曾定「tick 20 + 抓屏 ayolom 45 / legacy 20」──
    ///   该分工已于 2026-10-12（69bf409）废弃：抓屏也统一降到 20。
    ///   `CaptureEngine.swift:447` 的 `CMTime(value: 1, timescale: 45)` 是
    ///   **上限/初始值**，实际帧率由 `setCaptureHz(_:)` 按档位与应急态动态下发。
    ///
    /// ── 更早：45Hz 整体方案为什么不可行（勿再尝试）──
    /// 用户曾要求"720P + 45fps"，当时把 tick 也改成 45 —— **这是错的**：
    ///   · 45Hz 预算 = 22.2ms
    ///   · 但单帧实际工作量（实测）：yolopx letterbox 10.5ms + ayolom 模型 10.4ms
    ///     + V2 推理 8.5ms + world_model 3ms + 光流/控制/录制 2ms ≈ **36.9ms**
    ///   · ⟹ 45Hz 下**光 yolopx 就占 94% 预算**，V2/world_model/控制全部挤不下
    ///     → **游戏掉到 1-2 帧**（用户实测）
    ///
    /// 【为什么用具名常量而不是裸 1.0/30.0】全文件散落 6 处描述性注释各写一遍 "30Hz"，
    /// 裸字面量会逼着人肉找齐（本次改造就是活例）。抽成常量后，频率只有一个定义点。
    ///
    /// ── task-93（2026-10-11）：从 `static let 30.0` 改为**动态档位** ──
    ///
    /// 【用户需求原话】「正常那个模型（小型三合一 ayolom）有 45 赫兹，超大型的
    ///   （legacy：26S+光流+YOLOPX）直接让画面流切换回 30 赫兹，还能正好少传点数据，
    ///   为超大型给一点性能」
    ///
    /// 【两档定义】（key 名 **`perceptionMode`**，取值 **`"ayolom"` / `"legacy"`**，
    ///   与 `PerceptionModelFamily.rawValue` 一致；UI 侧 W4 下发，W5 交叉验证以此为准）
    ///   · `"ayolom"` → **20Hz**（小模型 A-YOLOM；原 45Hz 已降，见上方演进史）
    ///   · `"legacy"` → **20Hz**（大模型 YOLOPX；原 30Hz 已降）
    ///
    /// 【2026-10-12 现行值：两档推理都 20Hz】
    ///
    /// ── 用户拍板的两档频率 ──
    ///   · `.ayolom`（默认小模型 A-YOLOM）：推理 **20Hz** ＋ 抓屏 **20fps**
    ///   · `.legacy`（大模型 26S+光流+YOLOPX）：推理 **20Hz** ＋ 抓屏 **20fps**
    ///   两档推理频率相同（20Hz），区别只在模型大小与是否跑光流。
    ///
    /// ── 为什么是 20 而不是 30/45 ──
    ///   用户原话：「30 赫兹还是感觉有点过高，20 赫兹应该也够用了」
    ///   · 20Hz 预算 = 50ms（ayolom 10.42ms ≪ 50ms，绰绰有余）
    ///   · 比 30Hz 省 33% 推理量，比 45Hz 省 56%
    ///   · 2026-10-12 起抓屏也对齐到 20fps（不再为「每 tick 只消费 1 帧」的
    ///     画面流白烧带宽，见上方演进史）
    ///
    /// ── 抓屏与 tick 解耦 ──
    ///   · 抓屏侧由 `captureHz(forPerceptionMode:)` 单独映射（两档都 20）
    ///   · tick 侧由 `tickHz(forPerceptionMode:)` 映射（两档都 20）
    ///   · `applyPerceptionMode` 分别用两个频率调 `setTickHz` + `setCaptureHz`
    ///   · 应急冲刺时两个频率一起提到 45（`tickOnce` 的 sprint 联动）
    static var engineTickHz: Double = 20.0

    /// tick 定时器**已生效**的频率（诊断/心跳回显用；与 engineTickHz 同主线程读写）
    nonisolated(unsafe) private static var lastAppliedTickHz: Double = 0.0

    /// 抓屏流**已生效**的帧率（应急爆发联动用，避免每帧重复停启流）
    nonisolated(unsafe) private static var lastAppliedCaptureHz: Double = 20.0

    /// 当前档位的**基准**抓屏频率（sprint 结束后回退到此值）。
    /// 由 applyPerceptionMode / flushPendingTickHz 写入。
    /// 不直接查 `captureHz(forPerceptionMode:)` —— 因为引擎侧没有存
    /// perceptionMode 的字符串 key（DriveMode.rawValue 是中文，与
    /// captureHz 的 key "ayolom"/"legacy" 不匹配）。直接存频率值最简单。
    nonisolated(unsafe) private static var baseCaptureHz: Double = 20.0

    /// 动态调整引擎 tick 频率（task-93）。
    ///
    /// 【实现】`DispatchSourceTimer` 的 `schedule(deadline:repeating:leeway:)`
    /// 支持**重复调用**重新调度（官方语义：替换当前挂起的调度）——
    /// 不需要销毁重建 timer，也不丢已注册的 eventHandler。
    ///
    /// 【线程模型】**必须在主线程调用**（@MainActor 隔离）：
    ///   · 调用方：`case "config"` 的 `DispatchQueue.main.async` 块内
    ///   · `engineTicker` 是 `nonisolated(unsafe)` 静态持有；GCD 的调度方法本身
    ///     线程安全，这里收敛到主线程是为了保证 `engineTickHz` / `lastAppliedTickHz`
    ///     的读-改-写原子性（避免与读它的诊断路径竞争出旧值）。
    ///
    /// 【防抖】频率没变就不重调度（容差 0.01），避免 UI 每 tick 重发 config
    /// 造成 timer 无谓重排（重排会重置本次已等待的时间）。
    ///
    /// - Parameter hz: 目标频率（Hz）。非有限/≤0 直接忽略并记日志
    ///   （频率是性能参数不是安全参数，坏值静默回落而非崩溃）。
    @MainActor
    static func setTickHz(_ hz: Double) {
        guard hz.isFinite, hz > 0 else {
            engineLog("[ENGINE] ⚠️ setTickHz(非法定频 \(hz)) 已忽略")
            return
        }
        let clamped = min(max(hz, 5.0), 120.0)   // 防御性钳制：5~120Hz 合理区间
        if lastAppliedTickHz > 0, abs(lastAppliedTickHz - clamped) < 0.01 {
            return   // 没变，不重排（避免重复 config 抖动调度）
        }
        engineTickHz = clamped
        // ── deadline 用「now + 一个完整周期」，**不用 .now()** ──
        //
        // 【为什么】Lead 实测（2026-10-11，Swift 实验）直接对 running timer 调
        //   `schedule(deadline: .now(), repeating:)` 时，切换瞬间会出现 **0ms 间隔**：
        //     GAPS: 204,200,197,204,**[0]**,54,50,50,...
        //   —— 即"额外多触发一次 tick"。虽然本项目 `hold()/release()` 有
        //   `heldKeys.contains` 幂等守卫、`appendFrame` 有背压（重复 tick 不至于
        //   重复注入按键/重复写帧），但**多一次 tick 仍会**：
        //     · 多投递一次异步推理（`Task { @MainActor in ... }`，无幂等守卫）
        //     · 多发一轮 `refreshHeldKeys()` 的 keyDown（项目刻意要这个事件流，
        //       多一轮无害但有抖动）
        //   ⟹ 与其论证"无害"，不如**彻底消除不确定性**：等一个完整周期再起跑，
        //      切换点变成干净的「旧周期 → 新周期」，零额外 tick。
        //
        // 【代价】切档后首个新周期会晚到 1/clamped 秒（30→45Hz 时晚 ~22ms，
        //   45→30Hz 时晚 ~33ms）。一次性的、方向正确的（新频率的首帧本就该等
        //   一个周期），且 CPU 上限立刻由 `engineTickHz` 生效用于诊断回显。
        engineTicker?.schedule(deadline: .now() + 1.0 / clamped,
                               repeating: 1.0 / clamped,
                               leeway: .nanoseconds(0))
        lastAppliedTickHz = clamped
        engineLog("[ENGINE] tick 频率 → \(Int(clamped.rounded()))Hz（perceptionMode 档位切换，"
                  + "首帧延后一个周期以消除 0ms 双触发）")
    }

    /// 当前**已生效**的 tick 频率（供心跳/诊断如实回显，不谎报请求值）
    @MainActor
    static var currentTickHz: Double {
        lastAppliedTickHz > 0 ? lastAppliedTickHz : engineTickHz
    }

    /// 启动时登记初始频率（只由 `run()` 的 timer 装配段调用一次）
    @MainActor
    static func noteInitialTickHz(_ hz: Double) {
        lastAppliedTickHz = hz
    }

    // MARK: - task-93：档位感知的频率切换

    /// 档位 → 目标 tick 频率（单一映射点，避免散落魔数）
    ///
    /// key 名与取值（**W5 交叉验证以此为准**）：
    ///   · 命令字段名：**`perceptionMode`**
    ///   · 取值：**`"ayolom"`** → 20Hz ／ **`"legacy"`** → 20Hz
    ///     额外接受 **`"yolopx"`** 作为 `"legacy"` 的等价别名 ——
    ///     `PerceptionModelFamily` 的 case 是 `.yolopx`/`.ayolom`，而 UI 侧把
    ///     大模型档叫 "legacy"；两侧拼写不一致会导致**静默不切**，故两个都认。
    /// - Returns: 目标频率；未知值返回 nil（不猜，由调用方如实回执）
    ///
    /// ⚠️ 2026-10-12 现行值（历史：45/30 → 10-11 改 20/20 → 10-12 抓屏也对齐 20）：
    ///   · `.ayolom`（默认小模型 A-YOLOM）：推理 **20Hz** ＋ 抓屏 **20fps**
    ///   · `.legacy`（大模型 26S+光流+YOLOPX）：推理 **20Hz** ＋ 抓屏 **20fps**
    ///   两档推理与抓屏频率都相同（20Hz），区别只在模型大小与是否跑光流。
    ///   应急冲刺期间两者一起提到 45（见 `tickOnce` 的 sprint 联动）。
    static func tickHz(forPerceptionMode mode: String) -> Double? {
        switch mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ayolom":              return 20.0
        case "legacy", "yolopx":    return 20.0
        default:                    return nil
        }
    }

    /// 抓屏帧率档位映射（与 tickHz 配套，由 `applyPerceptionMode` 调用 `setCaptureHz`）
    /// - ayolom: 20fps（与推理 tick 20Hz 对齐；应急爆发由 EmergencyTakeover 提到 45）
    /// - legacy: 20fps
    static func captureHz(forPerceptionMode mode: String) -> Double? {
        switch mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ayolom":              return 20.0
        case "legacy", "yolopx":    return 20.0
        default:                    return nil
        }
    }

    // ── yolo26s 档位门（2026-10-19 用户拍板，goal-3279b59b 需求 5/7/8）──
    //
    // 【为什么引擎侧必须自己存一份档位】
    //   `DriveState.perceptionMode` 是 **UI 进程**的属性（AuroraDriveApp.swift:5414 定义），
    //   虽然引擎进程也 new 了自己的 DriveState（EngineMain.swift:1042），但全仓
    //   **没有任何代码在引擎侧写它** —— `selectPerceptionMode`（:5424）只 pushConfig。
    //   所以引擎进程的 `st.perceptionMode` 恒为初值 `.ayolom`，而 UI 侧的档位门
    //   `detectGateB`（tick 里）读的正是它。要让引擎侧 26S 真正按档位开停，
    //   必须在下发处把档位**写进 DriveState**，否则判据永远是 A 模型档。
    //
    // 【为什么默认是 "ayolom" 而不是 "legacy"】开机时引擎还没收到任何 config。
    //   · 引擎开机**本来就没有加载 yolo26s 的路径**（全仓 `yoloEngine.loadIfNeeded()`
    //     0 处在 EngineMain，见 grep 证据），默认 ayolom 不会产生"先加载再卸载"的白跑；
    //   · UI 侧默认档也是 `.ayolom`（用户明确要求「默认选择这个 A 模型」），两侧一致。
    //   若默认 legacy，则引擎开机就要装 9.2MB 权重，与"开机按档位决定是否加载"相反。
    //
    // 【回退开关】`AURORA_FORCE_YOLO26S=1` → A 模型档也常驻加载并跑 26S，
    //   完全恢复 2026-10-19 之前的旧行为。与 UI 侧 `DriveState.forceYolo26s`
    //   （AuroraDriveApp.swift:5576-5597）**同名环境变量、同语义**：
    //   引擎是 UI 用 Process spawn 的独立进程（EngineClient.swift:338-347 未设
    //   environment），两边各自读一次进程环境变量，值天然一致。
    //
    // 【线程】`applyPerceptionMode` 与 config 分支都在 @MainActor 上，本属性也只在
    //   这两处写；`run()` 的启动段虽然在 nonisolated 的 `run()` 里，但调用点包在
    //   `MainActor.assumeIsolated` 内 → 全部读写实际都收敛到主线程。
    //   仍标 `unsafe`：`enum EngineMain` 自身没有 actor 隔离标注，Swift 6 语言模式下
    //   可变静态存储必须有显式隔离声明，否则报 #MutableGlobalVariable。
    nonisolated(unsafe) private static var enginePerceptionMode: String = "ayolom"

    /// yolo26s 强制加载开关（引擎侧；与 UI 侧 `DriveState.forceYolo26s` 同语义）
    private static let forceYolo26s: Bool = {
        ProcessInfo.processInfo.environment["AURORA_FORCE_YOLO26S"] == "1"
    }()

    /// 按档位装卸 yolo26s（引擎侧唯一入口，由 `applyPerceptionMode` 调用）。
    ///
    /// 【为什么显式装载而不是让 tick 首帧自己发现】`YoloEngine.inferFast` 未加载时
    ///   会自己调 `loadIfNeeded()` 然后本帧 return（YoloEngine.swift:331-334）——
    ///   也就是说不会静默停摆，但首次进 legacy 那一帧要在推理队列上同步跑一次
    ///   `MLModel(contentsOf:)`（几十 ms 级）打一个尖峰。切档时主动装好并跑一次预热
    ///   （loadIfNeeded 内部自带 warmUp，YoloEngine.swift:200）比让首帧自己撞上更好。
    ///
    /// 【顺序】先写 DriveState.perceptionMode（让 tick 的档位门读到新档位），
    ///   再装卸模型。两步都在同一个 @MainActor 函数内连续执行，中间不会有 tick
    ///   插入，故不存在"门已放行但模型还没装"或"模型已卸但门还开着"的窗口。
    @MainActor
    private static func applyYolo26sForMode(_ mode: String) {
        let legacy = (mode == "legacy" || mode == "yolopx")
        // 档位写进 DriveState：tick 的档位门读的就是这个属性
        // （AuroraDriveApp 里 `forceYolo26s || perceptionMode == .legacy` 那一行）。
        // 引擎进程与 UI 进程跑的是同一份 tick() 代码，故一处写入即两进程同判据。
        if let st = EngineGlobals.state {
            st.perceptionMode = legacy ? .legacy : .ayolom
        }
        if Self.forceYolo26s {
            // 回退开关：无条件装上（下面 loadIfNeeded 内部 guard !isLoaded 幂等）
            EngineGlobals.state?.yoloEngine.loadIfNeeded()
            return
        }
        if legacy {
            EngineGlobals.state?.yoloEngine.loadIfNeeded()
            engineLog("[ENGINE] 感知档位 → legacy：yolo26s 已按需加载"
                      + "（loaded=\(EngineGlobals.state?.yoloEngine.isLoaded ?? false)）")
        } else {
            // A 模型档：卸掉 9.2MB 权重。unload 幂等（未加载时调用无副作用），
            // 并清空 detections —— 否则 .rule 档会拿陈旧的 26S 残留框开车
            //   （YoloEngine.swift:505-514 的安全论证）。
            EngineGlobals.state?.yoloEngine.unload()
            engineLog("[ENGINE] 感知档位 → A 模型（ayolom）：yolo26s 已卸载"
                      + "（不占 9.2MB 权重常驻，也不参与每帧推理）")
        }
    }

    /// 录制期间收到档位变更时**挂起**的目标频率（nil = 无挂起）
    ///
    /// 【为什么"延后"而不是"拒绝" —— 设计决策与理由】
    ///   两条路都不违反用户铁律，差别在**用户意图是否丢失**：
    ///   · **拒绝**：用户切档 → 引擎记日志"录制中，不切" → 频率**永远不变**。
    ///     用户必须"停止录制 → 再切一次档"，这是**静默失败**（用户以为切了）。
    ///     更糟的是模型档已由 `yolopxEngine` 切了、只有 tick 频率没跟上 → 两者不一致。
    ///   · **延后**：切档时记日志 + 挂起 → **录制停止时自动补上**。用户意图最终满足，
    ///     且录制会话内频率**恒定**（不破坏帧率语义）。
    ///   ⟹ **选延后**：既守住"录制中不切"的硬约束，又不丢用户意图。
    ///
    /// ⚠️ 2026-10-11 用户定档后 tick 与抓屏频率**不再相同**（ayolom: tick=20 / capture=45），
    ///   故挂起值也拆成两个。
    nonisolated(unsafe) private static var pendingTickHz: Double?
    nonisolated(unsafe) private static var pendingCaptureHz: Double?

    /// 档位变更入口（由 `case "config"` 的 `perceptionMode` 分支调用）
    /// - Parameters:
    ///   - mode: "ayolom" / "legacy"（大小写与空白容错）
    ///   - isRecording: 当前是否录制中（录制中只挂起、不立即切）
    /// - Returns: (是否立即生效, 面向用户的说明文本)
    @MainActor
    @discardableResult
    static func applyPerceptionMode(_ mode: String, isRecording: Bool) -> (applied: Bool, detail: String) {
        // ── ET-5 冲突处理（2026-10-12，task-111）：应急期间跳过档位频率应用 ──
        //
        // 【为什么需要这道 guard】
        //   applyPerceptionMode 会 setTickHz(20)（两档当前都是 20Hz）+ setCaptureHz。
        //   若应急冲刺（45Hz）或让位（5Hz）期间用户切档，档位频率会把应急频率覆盖掉。
        //
        // 【为什么选"从源头拦"而不是"只靠 tickOnce 每帧覆盖"】
        //   tickOnce 的每帧检测能兜住 tick 和抓屏频率，但档位切档会先跑一次
        //   setCaptureHz(20) 再被 tickOnce 覆盖回 sprint(45)——多一次无谓停启流。
        //   从源头拦更干净。
        //
        // 【失败模式】应急结束后（enterCruise），tickOnce 会读到 effectiveTickHz=20
        //   并 setTickHz(20)——与档位要求的 20Hz 一致，无需"补切"。
        //   若档位将来改成非 20Hz（如 legacy=30），则应急期间被跳过的档位会
        //   停在应急前的频率——**这是已知取舍**，如实回执说明让 UI 知情（见下）。
        guard !EmergencyTakeover.shared.takeoverActive else {
            return (false, "应急接管进行中（\(Int(EmergencyTakeover.shared.effectiveTickHz))Hz）"
                         + "：档位频率暂不应用（应急优先），结束后自动恢复")
        }
        guard let tickRate = tickHz(forPerceptionMode: mode),
              let capRate  = captureHz(forPerceptionMode: mode) else {
            return (false, "未知 perceptionMode「\(mode)」（仅接受 ayolom / legacy），频率未变")
        }
        if isRecording {
            pendingTickHz = tickRate
            pendingCaptureHz = capRate
            return (false, "录制中：tick 保持 \(Int(currentTickHz.rounded()))Hz / 抓屏保持当前帧率不变"
                         + "（避免改变已开始会话的帧率语义）；已挂起 tick=\(Int(tickRate))Hz + 抓屏=\(Int(capRate))fps，停止录制后自动生效")
        }
        setTickHz(tickRate)
        // 同步抓屏频率 + lastAppliedCaptureHz + baseCaptureHz
        // （tickOnce 的 sprint 联动据此判断值是否变了 / 结束后回退到基准值）
        EngineMain.lastAppliedCaptureHz = capRate
        EngineMain.baseCaptureHz = capRate
        Task { @MainActor in
            await EngineGlobals.state?.captureEngine.setCaptureHz(capRate)
        }
        // ── yolo26s 按档位装卸（2026-10-19，goal-3279b59b 需求 5/6）──
        //
        // 【为什么放在这里】本函数是引擎侧**唯一**收到档位事实的地方（config 的
        //   perceptionMode 分支只调它），所以"切档即时生效"只能落在这里。
        //   放在频率应用之后：频率与模型是同一笔用户意图，要么一起生效、要么
        //   一起被上面的 guard 挡掉，不会出现"频率切了但模型没切"的半拉子状态。
        //
        // 【为什么应急/录制两条早退路径不补模型装卸】
        //   · 应急早退：应急只改频率，不改模型归属；用户切档意图仍会被记在
        //     `enginePerceptionMode` 之外的 UI 侧，应急结束后下一次切档自然带上。
        //   · 录制早退：录制中"帧率语义恒定"的理由（见上方 pending 注释）同样
        //     适用于模型 —— 会话中途换检测网会让录到的数据前后不同源。
        //     挂起的频率在 flushPendingTickHz 补上，模型则由用户下次切档补。
        //   ⚠️ 这是**已知取舍**：录制中切档 → 频率与模型都延后。如实回执已说明
        //      "频率未变"，模型同理（ack detail 由调用方拼装，不含模型状态）。
        enginePerceptionMode = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        applyYolo26sForMode(enginePerceptionMode)
        return (true, "tick 已切到 \(Int(tickRate))Hz / 抓屏 \(Int(capRate))fps（perceptionMode=\(mode)）")
    }

    /// 录制停止时调用：把挂起的档位频率补上（无挂起则什么都不做）
    @MainActor
    static func flushPendingTickHz() {
        guard let tickRate = pendingTickHz else { return }
        let capRate = pendingCaptureHz
        pendingTickHz = nil
        pendingCaptureHz = nil
        setTickHz(tickRate)
        if let capRate {
            EngineMain.lastAppliedCaptureHz = capRate
            EngineMain.baseCaptureHz = capRate
            Task { @MainActor in
                await EngineGlobals.state?.captureEngine.setCaptureHz(capRate)
            }
        }
        engineLog("[ENGINE] 录制已停止 → 补切挂起频率 tick=\(Int(tickRate))Hz"
                  + (capRate.map { " / 抓屏=\(Int($0))fps" } ?? ""))
    }

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
            reason: "AuroraDrive 后台驾驶引擎：持续 20Hz 抓屏推理与按键注入")
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

        // ── 7. DriveState 闭环 + 45Hz tick（照搬 ContentView 驱动方式）──
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
            // ── 开机按档位决定 yolo26s 装不装（2026-10-19，goal-3279b59b 需求7）──
            //
            // 【为什么开机就定】引擎开机时还没收到任何 config（UI 连上后才推），
            //   若不在这里定一次，`enginePerceptionMode` 的初值只活在变量里、
            //   DriveState.perceptionMode 也还是初值 —— 两边虽然都默认 ayolom，
            //   但没有日志可核对，用户问"开机到底装没装"时只能靠猜。
            //   这一行让开机行为在日志里可见，且 `applyYolo26sForMode` 本身幂等
            //   （A 模型档卸一个没装过的模型是无副作用的），重复调用无代价。
            applyYolo26sForMode(enginePerceptionMode)
        }
        engineLog("[ENGINE] DriveState 已创建")

        let tickQueue = DispatchQueue(label: "aurora.engine.tick", qos: .userInteractive)
        let tickTimer = DispatchSource.makeTimerSource(queue: tickQueue)
        // ⚠️ task-93（2026-10-11）：初始频率取 `engineTickHz`（默认 **30Hz**），
        //   之后由 `setTickHz(_:)` 按 `perceptionMode` 档位动态重调度：
        //     "ayolom" → 45Hz ／ "legacy" → 30Hz
        //   这**一处**决定推理 / 控制 / 录制三条路径的 tick 速率（它们都挂在
        //   `tickOnce()` 上），故改这里即全链路生效。
        //   注：`leeway` 保持 0 —— 主循环要求准点，不引入调度抖动。
        //   （下方 task-80 的历史注释已过时：抓屏侧与 tick 侧自 task-93 起
        //    由档位解耦，不再强绑同一个 45。）
        tickTimer.schedule(deadline: .now(),
                           repeating: 1.0 / EngineMain.engineTickHz,
                           leeway: .nanoseconds(0))
        tickTimer.setEventHandler {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    EngineMain.tickOnce()
                }
            }
        }
        tickTimer.resume()
        engineTicker = tickTimer
        // task-93：记录**初始已生效频率**，供 setTickHz 防抖比较与心跳回显。
        // 必须在 resume 之后置位（此前 timer 尚未运行，回显 0 会让 UI 误判"没在 tick"）。
        MainActor.assumeIsolated {
            EngineMain.noteInitialTickHz(EngineMain.engineTickHz)
        }

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

        // 如实打印**当前已生效**的 tick 频率（不是常量请求值）：
        //   engineTickHz 只是启动默认值，applyPerceptionMode 与应急态都会改它。
        //   原实现硬编码「tick 45Hz」—— 45Hz 方案早已废弃，20Hz 定档后这句一直是谎报。
        //   ⚠️ 这里在 nonisolated 的 run() 里，不能直接读 @MainActor 的 currentTickHz
        //      （实测编译报 actor-isolated 错），改用同一份 @MainActor 静态存储的
        //      nonisolated(unsafe) 原始值 lastAppliedTickHz —— 语义等价（它记的就是
        //      「已生效频率」，见 noteInitialTickHz 与 setTickHz）。
        let tickNowHz = lastAppliedTickHz > 0 ? lastAppliedTickHz : engineTickHz
        engineLog("[ENGINE] 就绪（tick \(Int(tickNowHz.rounded()))Hz / 心跳 1Hz / socket / shm）")
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

        // ── ET-5 应急频率接线（2026-10-12，task-111）──
        //
        // EmergencyTakeover 状态机算出的频率（20巡航 / 45冲刺 / 5让位）。
        // 每帧检查：变了就 setTickHz（setTickHz 内有 0.01 容差防抖，同值不重排）。
        //
        // 【为什么放这里（st.tick() 之后、shm publish 之前）】
        //   st.tick() 里 ET-4 已喂了 noteTickGap / noteModelDegraded →
        //   EmergencyTakeover 的 effectiveTickHz 可能在此刻发生变化（如连续 3 帧
        //   >80ms → enterSprint → 45Hz）。紧跟着读，能在本帧就切频，不等到下一帧。
        //
        // 【与 applyPerceptionMode 的冲突怎么处理】
        //   applyPerceptionMode 也会调 setTickHz(20)（当前两档都是 20Hz）。
        //   应急期间若它先跑了 setTickHz(20)，本帧 tickOnce 会立刻覆盖回 45/5。
        //   但更稳的做法是**从源头拦**：applyPerceptionMode 开头加了
        //   `guard !EmergencyTakeover.shared.takeoverActive`（见该函数），
        //   应急期间整个函数直接 return，连 setCaptureHz 都不碰。
        //   ⟹ 两层防线：① applyPerceptionMode 的 guard（预防）② 本处每帧检测（兜底）
        let wantHz = EmergencyTakeover.shared.effectiveTickHz
        if abs(wantHz - EngineMain.currentTickHz) > 0.01 {
            EngineMain.setTickHz(wantHz)
        }

        // ── 应急爆发：抓屏跟着一起冲（2026-10-12 用户要求）──
        //
        // 【为什么需要】原本 EmergencyTakeover「只提推理 tick，抓屏不动」（见上）。
        //   但用户指出：正常态抓屏与推理都该是 20（抓屏 45 时每 tick 只消费 1 帧，
        //   多出的 25 帧被跳帧丢弃，纯浪费带宽/CPU）。既然正常态对齐到 20，
        //   爆发态就该两个一起冲 45 —— 否则"爆发"只是 tick 空转、画面供给没跟上。
        //
        // 【状态对应】
        //   cruise(sprinting=false) → tick 20 / 抓屏 20（对齐，不浪费）
        //   sprint(sprinting=true)  → tick 45 / 抓屏 45（一起冲，抗系统）
        //   yield (userHolding)     → tick  5 / 抓屏 20（用户接管，预览不卡）
        //   注意用 `sprinting` 而非 `takeoverActive`：让位态 takeoverActive 仍为 true，
        //   但那时 AI 已让位、不该再抢抓屏带宽。
        //
        // 【为什么不每帧调】setCaptureHz 内部虽有同值短路（CaptureEngine:667），
        //   但为清晰起见这里也做同值判断；且 setCaptureHz 是 async（可能停启流），
        //   只在值真变时触发一次，避免每帧派发 Task。
        let wantCapHz = EmergencyTakeover.shared.sprinting
            ? EmergencyTakeover.sprintHz
            : EngineMain.baseCaptureHz
        if abs(wantCapHz - EngineMain.lastAppliedCaptureHz) > 0.01 {
            EngineMain.lastAppliedCaptureHz = wantCapHz
            engineLog("[ENGINE] 抓屏频率 → \(Int(wantCapHz))fps"
                      + "（\(EmergencyTakeover.shared.sprinting ? "应急冲刺联动" : "档位默认")）")
            Task { @MainActor in
                await EngineGlobals.state?.captureEngine.setCaptureHz(wantCapHz)
            }
        }

        // UI 开了插帧/要清晰画面时发全分辨率帧，否则发 480 宽缩略帧（省带宽）
        var full: CVPixelBuffer? = nil
        if EngineGlobals.wantFullFrame {
            EngineGlobals.latestFullFrameLock.lock()
            full = EngineGlobals.latestFullFrame
            EngineGlobals.latestFullFrameLock.unlock()
        }
        EngineGlobals.shm?.publish(
            image: st.currentFrameCG,
            // ── 检测框来源：26S 优先，空则回落小模型（2026-10-19，需求5 连带）──
            //
            // 【为什么必须回落】A 模型档下 yolo26s 不加载/不推理 → `st.yoloEngine.detections`
            //   恒为空数组 → 原来直接发它，UI 侧 `remoteDetections` 就是空的 →
            //   `displayDetections` 在引擎模式下**没有框可画**（UI 进程的 yolopx 是空转的，
            //   tickEngineMode 早退不跑本地推理，那条"优先 yolopx 的框"在引擎模式下
            //   永远取不到值）。这是本次档位门在引擎模式下暴露的真实缺口，不是原有缺陷。
            //
            // 【为什么回落到 yolopx 而不是改协议】UI 侧 `displayDetections` 的既定语义
            //   （`preferYolopxDetections` 那个条件，AuroraDriveApp.swift:4219）
            //   就是「小模型优先、无框才回落 26S」。
            //   引擎侧照同一优先级发，两端判据一致，不必给协议加字段（方案 Z）。
            //
            // 【legacy 档行为是否变了】没变。legacy 档下 26S 每两帧出框，`yoloEngine.detections`
            //   非空 → 取的就是它；只有 26S 恰好空的那一帧才顶一下，与改前"偶有真空帧"同性质。
            detections: st.yoloEngine.detections.isEmpty
                ? st.yolopxEngine.detections
                : st.yoloEngine.detections,
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

        // ⚠️ 2026-10-10 修复 P2【未捕获时谎报成功】（w8-verify task-63 独立发现）：
        //   未在捕获时 `applyMode` 走早退分支（只记期望、**不校验窗口存在性**、
        //   不写 `lastModeError`）→ 本函数返回 error=nil → ack 报 `ok=true`，
        //   但该窗口可能根本不存在。后续 `start()` 才在引擎日志里暴露
        //   「目标窗口 #N 已不存在 → 画面流失败」—— **ack 说了谎**。
        //   修法：未捕获时**提前校验窗口存在性**（枚举一次 SCShareableContent），
        //   不存在则直接返回错误，不让 ok=true 溜出去。
        //   注意：这里只在**窗口模式**下多付一次枚举成本；全屏模式不需要校验。
        if !st.captureEngine.isCapturing, case .window(let wid) = capMode {
            if let err = await validateWindowExists(windowID: wid) {
                return (capMode, err)
            }
        }

        await st.captureEngine.applyMode(capMode)
        // applyMode 无返回值：成功与否看它是否写入 lastModeError（见 CaptureEngine 注释：
        // 「失败处理：保持原模式不变，把原因写进 lastModeError」）。
        // ⚠️ 必须在 await 之后再读 —— applyMode 是 async，读早了拿不到本次结果。
        let err = st.captureEngine.lastModeError
        if err != nil {
            // P3 修复：失败时返回**实际生效的模式**（captureMode），不是请求的模式 ——
            //   否则调用方只读 data.captureMode 会误以为切换成功。
            return (st.captureEngine.captureMode, err)
        }
        return (capMode, nil)
    }

    /// 校验某个窗口当前是否可捕获（未捕获状态下用）。
    /// - Returns: 不存在时返回错误描述；存在返回 nil。
    @MainActor
    private static func validateWindowExists(windowID: CGWindowID) async -> String? {
        do {
            let content = try await SCShareableContent.current
            if CaptureEngine.findWindow(id: windowID, in: content) == nil {
                return "窗口 #\(windowID) 已不存在（可能已关闭）"
            }
            return nil
        } catch {
            return "无法获取窗口列表（\(error.localizedDescription)）"
        }
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
                // P4（w8-verify 发现）：`frames` 是**录制帧数**（recordEngine.frameCount），
                // 不开录制恒为 0 —— 断言"抓屏活着"会误判。`captureFrames` 才是
                // 抓屏累计帧数（CaptureEngine 的帧回调计数），任何时候都反映抓屏是否在跑。
                "captureFrames": 0,
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
                "digestMode": false,
                "digestedEvents": 0,
                "postedEvents": 0,
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
            "captureFrames": st.captureEngine.capturedFrameCount,
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
            // 消化模式（2026-10-10）：供 AI/脚本确认「按键是否被消化」，
            //   与 digestedEventCount 一起做「链路活但零注入」的证据。
            "digestMode": st.controlEngine.digestMode,
            "digestedEvents": st.controlEngine.digestedEventCount,
            "postedEvents": st.controlEngine.postedEventCount,
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
            // 【防御】老版 UI 不发这个字段 → **沿用引擎侧当前状态**（不再无条件回落 "first"）。
            //
            // ⚠️ 2026-10-10 修复（w5-search 验证 E 发现）：
            //   原实现 `(obj["perspective"] as? String) ?? "first"` —— 不带 perspective
            //   的命令（如 `record off`、或脚本直发 `record on`）一律回落 "first"，
            //   配合 `if recOn` 里的赋值就会**把已选好的 TPV 打回 FPV**。
            //   w5 实测：`record on`（不带 perspective）→ view.txt 变 FPV（与预期不符）。
            //   修法：缺省时读引擎侧当前视角（保持上次选择）——**在 MainActor 块内解析**
            //   （`recordPerspective` 是 MainActor 隔离属性，不能在 nonisolated 上下文读）。
            //   仅在 state 未就绪时才回落 "first"（与新引擎首启行为一致）。
            //   生产路径不受影响（UI 的 isRecording.didSet 总是带 perspective），
            //   但让"不传=保持"语义自洽，且脚本/Debug 路径不再静默改视角。
            let perspectiveRaw: String? = obj["perspective"] as? String
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let recPerspective = RecordEngine.normalizePerspective(
                        perspectiveRaw
                            ?? EngineGlobals.state?.recordPerspective
                            ?? "first")
                    guard let st = EngineGlobals.state else {
                        EngineMain.sendAck(id: ackID, cmd: type, ok: false,
                                           detail: "引擎状态未就绪（EngineGlobals.state == nil）",
                                           server: server)
                        return
                    }
                    // ⚠️ 2026-10-10 修复：**只在开始录制时**同步这些会话级参数。
                    //   原实现无条件写 → `record off` 命令不带 perspective 时回落 "first"，
                    //   把 st.recordThirdPerson 覆盖回 false → **下次录制又变 FPV**
                    //   （实测：stop 的 ack 报 `视角=first(FPV)`，而本次实际录的是 TPV）。
                    //   这些参数只在 `start()` 那一刻被消费（视角决定 view.txt，中途不可改），
                    //   故 stop 时不该动它们。
                    if recOn {
                        st.glyphMode = recGlyph
                        st.expertMode = recExpert
                        // 同步视角到引擎侧 DriveState：`isRecording` 的 didSet 也会读
                        // `recordPerspective` 去 start()，不同步的话那条路径会用默认 first。
                        st.recordThirdPerson = (recPerspective == "third")
                    }
                    // 先 start/stop 再置 isRecording：start() 才会建目录、写 view.txt，
                    // 顺序反了会出现「开关已开、目录还没建」的空窗（心跳上报 session="-"）。
                    if recOn, !st.recordEngine.isRecording {
                        st.recordEngine.glyphMode = recGlyph
                        // 同步专家模式标志 → RecordEngine 用它决定 stop() 时是否做
                        // 「标签全零」告警（w4 V4 发现：引擎 KeyboardMonitor 可能
                        // 收不到键盘事件，导致专家标签静默全零）。
                        st.recordEngine.expertMode = recExpert
                        st.recordEngine.start(perspective: recPerspective)
                    } else if !recOn, st.recordEngine.isRecording {
                        st.recordEngine.stop()
                        // task-93：录制停止 → 补切录制期间挂起的档位频率
                        //（"延后"策略的落点，理由见 applyPerceptionMode 注释）
                        EngineMain.flushPendingTickHz()
                    }
                    st.isRecording = recOn
                    let dir = st.recordEngine.sessionURL?.lastPathComponent ?? "-"
                    // ⚠️ 2026-10-10 修复（w5-search 验证 E 发现）：**ack 必须报"实际生效"视角**，
                    //   不能回显命令解析出的 `recPerspective`。
                    //   原实现回显命令值 → 出现「ack 说 first(FPV)、而磁盘 view.txt 是 TPV」
                    //   的自相矛盾（`record off` 不带 perspective 时必然发生）。
                    //   以 `recordEngine.sessionPerspective`（真正写进 view.txt/meta.json 的值）
                    //   为准；它为空（未开始过录制）时才回退到命令值。
                    let effectivePerspective = st.recordEngine.sessionPerspective ?? recPerspective
                    let viewLabel = effectivePerspective == "third" ? "TPV" : "FPV"
                    engineLog("[ENGINE] 录制\(recOn ? "开始" : "停止")：字模=\(recGlyph) 专家=\(recExpert) "
                              + "视角=\(effectivePerspective)(\(viewLabel)) 会话=\(dir)")
                    // 立即回执：心跳周期 1s，不即时上报的话 UI 会先看到「还没录」，
                    // 把开关弹回去（UI 侧也有宽限期，这里是双保险）。
                    EngineMain.sendHeartbeat(reason: "record-ack")
                    // ok 以"实际是否处于请求的状态"为准，不谎报
                    EngineMain.sendAck(
                        id: ackID, cmd: type, ok: st.isRecording == recOn,
                        detail: "录制\(recOn ? "开始" : "停止")：视角=\(effectivePerspective)(\(viewLabel)) 会话=\(dir)",
                        data: ["recording": st.isRecording, "frames": st.recordEngine.frameCount,
                               "session": dir, "perspective": effectivePerspective],
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
                    // ── A 模型档下把 26S 一起卸掉（2026-10-19，goal-3279b59b 需求5）──
                    //
                    // 【为什么必须补这一步】`reloadModel()` 只把 model 置 nil + isLoaded=false，
                    //   而 `YoloEngine.inferFast` 未加载时会**自己调 loadIfNeeded()**
                    //   （YoloEngine.swift:331-334）。A 模型档下 26S 本该不在内存里，
                    //   这条 reloadmodel 命令会把它重新拉起来 —— 于是"训练完点一下应用"
                    //   就静默破坏了档位门，之后每两帧跑一次 26S 抢 ANE/GPU。
                    //   热替换的语义是"下次推理重读磁盘"，与"该档位要不要这个模型"是两件
                    //   独立的事，故这里按当前档位把装卸状态恢复回来。
                    applyYolo26sForMode(enginePerceptionMode)
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
            // ── ET-5：应急接管「用户接管让位」信号（2026-10-12，task-111）──
            //
            // 【为什么必须走 config 下发】ET-6 审计（§4）实测确认：
            //   引擎进程**收不到物理按键**（dispatchMain 不 spin run loop +
            //   未申请 Input Monitoring）→ 引擎进程内的 KeyboardMonitor 是死的。
            //   所以「用户按下了受控键」这个事件必须由 **UI 进程**（它的
            //   KeyboardMonitor 能收到系统键盘事件）经 config 命令转发到这里。
            //
            // 【语义】takeover=true = 用户按下受控键 → 让位（5Hz，把算力让给用户）
            //         takeover=false = 用户松开 → 回巡航（20Hz）
            //   EmergencyTakeover.noteUserKeyDown()/noteUserKeyUp() 内部自带状态守卫
            //   （只在冲刺态响应 keyDown、只在让位态响应 keyUp），故这里无条件转发即可，
            //   不需要引擎侧再做状态判断 —— 语义单一，好核对。
            let cTakeover = obj["takeover"] as? Bool
            // 消化模式：真正注入按键的是**引擎进程**，UI 侧开关必须下发到这里，
            //   否则「UI 显示已消化、引擎照旧真按键」—— 那是最危险的不一致。
            let cDigest = obj["digest"] as? Bool
            // task-93：档位感知的动态 tick 频率。
            //   key 名 **`perceptionMode`**，取值 **"ayolom" / "legacy"**（W4 下发、W5 对拍）。
            //   两档：ayolom → 20Hz ／ legacy → 20Hz（映射见 tickHz(forPerceptionMode:)）。
            let cPerceptionMode = obj["perceptionMode"] as? String
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
                    // ⚠️ 必须**同时**改 st.digestMode（DriveState 属性）——
                    //   否则下一帧 tick 的同步段 `if controlEngine.digestMode != digestMode`
                    //   会用旧的 st.digestMode（false）把 controlEngine.digestMode
                    //   改回来 = 消化模式开了立刻被关掉（用户报「没任何用处」的根因）。
                    if let v = cDigest {
                        st.digestMode = v
                        if st.controlEngine.digestMode != v {
                            st.controlEngine.digestMode = v
                        }
                        engineLog("[ENGINE] 🧪 消化模式\(v ? " ON（不真发按键）" : " OFF（恢复真注入）")")
                    }
                    // speedLimit 不是「显示项」：它经 InferenceEngine 变成
                    // vehicle_state[4] = speed_limit_norm 直接参与推理，不同步会
                    // 让 UI 显示 40 而模型仍按 120 决策。
                    if let v = cSpeedLimit { st.speedLimit = v }
                    // ── ET-5：转发「用户接管让位」信号给状态机（2026-10-12）──
                    // 在 applied 回显**之前**处理，这样反降级信号也算"已应用的键"。
                    // noteUserKeyDown/Up 内部有状态守卫（非冲刺态按键无意义、
                    // 非让位态松开无意义），故这里只需如实转发，不必判状态。
                    if let v = cTakeover {
                        if v {
                            EmergencyTakeover.shared.noteUserKeyDown()
                            engineLog("[ENGINE] 🚨 应急：用户接管（按下受控键）→ 让位 "
                                      + "\(Int(EmergencyTakeover.shared.effectiveTickHz))Hz")
                        } else {
                            EmergencyTakeover.shared.noteUserKeyUp()
                            engineLog("[ENGINE] ✅ 应急：用户松开受控键 → 巡航 "
                                      + "\(Int(EmergencyTakeover.shared.effectiveTickHz))Hz")
                        }
                    }
                    // 如实回显"本次真正写入了哪些键"（未传的键不写、也不虚报）
                    var applied: [String: Any] = [:]
                    if let v = cSport { applied["sport"] = v }
                    if let v = cCtrlDisabled { applied["controlDisabled"] = v }
                    if let v = cForceRule { applied["forceRule"] = v }
                    if let v = cExpert { applied["expert"] = v }
                    if let v = cGlyph { applied["glyph"] = v }
                    if let v = cThresh { applied["degradeThreshold"] = v }
                    if let v = cSpeedLimit { applied["speedLimit"] = v }
                    // Lead 新增的消化模式（digest）也一并回显，保持 applied 是"真实写入全量"
                    if let v = cDigest { applied["digest"] = v }
                    // ET-5：takeover 也纳入回显（UI 可据此确认引擎真的收到了让位信号）
                    if let v = cTakeover { applied["takeover"] = v }

                    // ── task-93：档位感知的动态 tick 频率 ──
                    // 立即生效 vs 录制中挂起，由 applyPerceptionMode 内部判定；
                    // 未知取值**如实回执 ok=false**（不静默吞掉，否则 UI 以为切了）。
                    var tickNote: String?
                    // ⚠️ 2026-10-11 Lead 修复（w8-verify 复检的 P1「谎报成功」）：
                    //   原实现在下方 ack 里**硬编码 `ok: true`**，无视 applyPerceptionMode 的返回值
                    //   → 两种 `(applied: false)` 情形（未知档位 / 录制中挂起）也回执成功，
                    //     UI 会误以为已切换（静默失败）。对照同文件其它分支都有 `ok: false` 处理。
                    //   ⚠️ 注意语义：`ok:false` 这里表示"perceptionMode 这一项没立即生效"，
                    //     不代表整个 config 失败（其它字段仍是成功的），故 detail 里必须说清。
                    var perceptionOK = true
                    if let mode = cPerceptionMode {
                        let r = EngineMain.applyPerceptionMode(mode, isRecording: st.isRecording)
                        applied["perceptionMode"] = mode
                        // 回显**实际生效**频率（挂起时即当前值，不谎报目标值）
                        applied["tickHz"] = Int(EngineMain.currentTickHz)
                        // 26S 装载实况：让 UI/脚本能核对「切到 A 模型档后 26S 真的卸了」
                        // （用户铁律：隐蔽开关是排查噩梦 —— 装卸状态必须可观测）。
                        applied["yoloLoaded"] = st.yoloEngine.isLoaded
                        perceptionOK = r.applied
                        tickNote = r.detail
                    }

                    let baseDetail = applied.isEmpty
                        ? "config 未包含任何可识别字段（无改动）"
                        : "已同步 \(applied.count) 个参数"
                    EngineMain.sendAck(
                        id: ackID, cmd: type, ok: perceptionOK,
                        detail: tickNote.map { "\(baseDetail)；\($0)" } ?? baseDetail,
                        data: ["applied": applied,
                               "tickHz": Int(EngineMain.currentTickHz)],
                        server: server)
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
            // ⚠️ 这里**不用** `DispatchQueue.main.async { MainActor.assumeIsolated { Task { … } } }`：
            //    在 assumeIsolated 闭包内嵌 Task 会让 Swift 6 编译器类型检查崩掉
            //    （实测两种报错：`ambiguous use of init(name:priority:operation:)`，
            //      改成 `Task<Void, Never>` 后升级为 "failed to produce diagnostic"）。
            //    改用 `Task { @MainActor in … }`：一步到位跳到主 actor，语义等价且无嵌套。
            //    引擎无 GUI，主队列就是主 actor，行为与既有 async 派发一致。
            Task { @MainActor in
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
                    // ⚠️ P3 修复（w8-verify task-63 独立发现）：失败时 `capMode` 是
                    //   **请求的**模式，而实际生效的是 `captureEngine.captureMode`
                    //   （applyMode 失败保持原模式）。若 data 里报请求值，调用方只读
                    //   data 会误以为切换成功了 —— 与 detail 自相矛盾。
                    //   故失败时改写为**实际生效模式**，并把请求值另存 requestedMode。
                    let actual = EngineGlobals.state?.captureEngine.captureMode
                    data["requestedMode"] = capMode.label
                    data["captureMode"] = actual?.label ?? "unknown"
                    data["mode"] = (actual?.isWindowMode ?? false) ? "window" : "fullscreen"
                    data.removeValue(forKey: "windowID")
                    if case .window(let id) = actual { data["windowID"] = Int(id) }
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
        // ⚠️ 2026-10-12 ET-9 修复（Lead 发现的致命缺陷）：
        //   应急接管状态机（EmergencyTakeover）在**两个进程各有一个实例**，互不相通。
        //   · 引擎进程 isActive=false → 跑完整 tick → 实例能触发冲刺（45Hz 生效 ✅）
        //   · UI 进程   isActive=true  → tickEngineMode() 早退 → 实例**永不触发** ❌
        //   而 ET-3 的「请接管」横幅读的是 **UI 实例** → 横幅永不显示（安全功能失效）。
        //   修法：引擎把真实的 takeover 状态经 heartbeat（1Hz）回传，UI 侧解析后同步到
        //   自己的实例。1Hz 延迟可接受——引擎侧的 45Hz 冲刺是**零延迟**生效的，
        //   heartbeat 只负责让 UI 把横幅显示出来。
        let et = EmergencyTakeover.shared
        let json = """
        {"type":"heartbeat","proto":\(EngineClient.protocolVersion),"ts":\(Int(Date().timeIntervalSince1970)),"fps":\(String(format: "%.1f", fps)),"detections":\(detCount),"isDriving":\(st.isDriving),"isStreaming":\(st.isStreaming),"mode":"\(st.mode)","modeRaw":"\(st.mode.rawValue)","speed":\(String(format: "%.1f", st.effectiveSpeed)),"speedKmh":\(String(format: "%.1f", st.speedKmh)),"confidence":\(String(format: "%.3f", st.confidence)),"recording":\(st.isRecording),"frames":\(st.recordEngine.frameCount),"pid":\(getpid()),"takeover":\(et.takeoverActive),"userHolding":\(et.userHoldingKey),"reason":"\(reason)"}
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
