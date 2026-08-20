// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  MinimapLocatorView.swift — 左上角分块小地图（纯视觉定位显示）
//
//  功能：把大地图切成 8×8=64 块，只显示自车当前所在的那一块，并在块内
//        用「朝向箭头」标出自车位置；点击块内任意处可设目标点（供纯规则转向）。
//
//  数据源：state.locatorX/Y（大地图像素坐标）、locatorHeading、locatorTarget
//  来源：VisualLocator（纯视觉匹配） ｜ 由 DriveState.updateLocator 写入。
//
//  仅显示用，不进入决策关键链；无定位结果时显示黑底占位 + 提示。
//  复用完整大地图 bigworldmapSecond.png，按需裁剪当前块（缓存整图一次）。
// ============================================================================
import SwiftUI
import CoreGraphics
import ImageIO

/// 左上角分块小地图
struct MinimapLocatorView: View {
    @Bindable var state: DriveState

    /// 大地图边长与分块
    static let mapSide: Double = 11264
    static let blocksPerEdge = 8
    static let blockSide: Double = mapSide / Double(blocksPerEdge)   // 1408

    /// 小窗显示尺寸（pt）
    private let viewSize: CGFloat = 220

    /// 已解码的完整大地图（线程安全缓存；后台解码，避免主线程卡顿）
    @State private var blockImage: CGImage? = nil    // 当前块
    @State private var loadedBlock: Int = -1
    /// 解码/裁剪去哪一队列（后台）
    private let blockQueue = DispatchQueue(label: "aurora.minimap.block", qos: .userInitiated)

    /// 当前块索引（行主序）
    private var currentBlock: Int {
        let bx = min(Self.blocksPerEdge - 1, max(0, Int(state.locatorX / Self.blockSide)))
        let by = min(Self.blocksPerEdge - 1, max(0, Int(state.locatorY / Self.blockSide)))
        return by * Self.blocksPerEdge + bx
    }

    /// 块内相对位置 [0,1]
    private var relX: CGFloat {
        let fx = state.locatorX - Double(currentBlock % Self.blocksPerEdge) * Self.blockSide
        return CGFloat(min(max(fx, 0), Self.blockSide) / Self.blockSide)
    }
    private var relY: CGFloat {
        let fy = state.locatorY - Double(currentBlock / Self.blocksPerEdge) * Self.blockSide
        return CGFloat(min(max(fy, 0), Self.blockSide) / Self.blockSide)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // ── 地图块底图 + 覆盖层 ──
            ZStack {
                if let img = blockImage {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: viewSize, height: viewSize)
                } else {
                    Color.black.frame(width: viewSize, height: viewSize)
                }

                if state.locatorFound {
                    // 朝向箭头（Canvas 自绘：北=上，顺时针）
                    Canvas { ctx, size in
                        let center = CGPoint(x: relX * size.width, y: relY * size.height)
                        var t = CGAffineTransform(translationX: center.x, y: center.y)
                        t = t.rotated(by: CGFloat(state.locatorHeading * .pi / 180))
                        let tri = Path { p in
                            p.move(to: CGPoint(x: 0, y: -11).applying(t))
                            p.addLine(to: CGPoint(x: -7, y: 8).applying(t))
                            p.addLine(to: CGPoint(x: 7, y: 8).applying(t))
                            p.closeSubpath()
                        }
                        ctx.fill(tri, with: .color(Theme.cyan))
                        ctx.stroke(tri, with: .color(.white.opacity(0.8)), lineWidth: 1)
                    }
                    // 中心小圆点锚点
                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                        .position(x: relX * viewSize, y: relY * viewSize)
                }

                // 目标点标记 + 自车连线
                if let t = state.locatorTarget {
                    let tx = CGFloat(((t.x - originX) / Self.blockSide) * Double(viewSize))
                    let ty = CGFloat(((t.y - originY) / Self.blockSide) * Double(viewSize))
                    if tx >= 0, tx <= viewSize, ty >= 0, ty <= viewSize {
                        Path { p in
                            p.move(to: CGPoint(x: relX * viewSize, y: relY * viewSize))
                            p.addLine(to: CGPoint(x: tx, y: ty))
                        }
                        .stroke(Theme.orangeRed.opacity(0.7), lineWidth: 1.5)
                        Circle()
                            .fill(Theme.orangeRed)
                            .frame(width: 8, height: 8)
                            .position(x: tx, y: ty)
                    }
                }
            }
            .frame(width: viewSize, height: viewSize)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { p in
                let mx = Double(p.x / viewSize) * Self.blockSide + originX
                let my = Double(p.y / viewSize) * Self.blockSide + originY
                state.setLocatorTarget(x: mx, y: my)
            }

            // ── 状态行 ──
            if state.locatorFound {
                // 诊断：显示坐标 + 相对位置，帮助排查"定位不准"问题
                Text("块 \(currentBlock) · 地图px(\(Int(state.locatorX)),\(Int(state.locatorY)))"
                     + " rel(\(String(format: "%.3f", relX)),\(String(format: "%.3f", relY)))"
                     + " ↗\(Int(state.locatorHeading))°")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.cyan)
            } else {
                Text("小地图定位…")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(6)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { ensureBlockLoaded() }
        .onChange(of: currentBlock) { _, _ in ensureBlockLoaded() }
    }

    /// 当前块的原图左上像素（大地图坐标）
    private var originX: Double {
        Double(currentBlock % Self.blocksPerEdge) * Self.blockSide
    }
    private var originY: Double {
        Double(currentBlock / Self.blocksPerEdge) * Self.blockSide
    }

    /// 解码整图、裁剪当前块：全部在后台 `blockQueue`，主线程只接收完成后 CGImage 并赋 @State。
    /// 整图经线程安全缓存复用（只解码一次），避免主线程处理 11264² 大地图导致 UI 卡死。
    private func ensureBlockLoaded() {
        let wantBlock = currentBlock
        if loadedBlock == wantBlock, blockImage != nil { return }
        let desiredX = Double(wantBlock % Self.blocksPerEdge) * Self.blockSide
        let desiredY = Double(wantBlock / Self.blocksPerEdge) * Self.blockSide

        blockQueue.async { [self] in
            if MinimapBlockCache.shared.display() == nil {
                MinimapBlockCache.shared.setDisplay(Self.loadDisplayMap())
            }
            guard let src = MinimapBlockCache.shared.display() else { return }
            // 显示图是整图降采样后的（scale < 1），块裁剪坐标同步换算：
            // 显示图里当前块的左上角 = 原图左上角 × scale
            let scale = CGFloat(src.width) / CGFloat(Self.mapSide)
            let crop = CGRect(x: desiredX * Double(scale),
                              y: desiredY * Double(scale),
                              width: Self.blockSide * Double(scale),
                              height: Self.blockSide * Double(scale))
            guard let block = src.cropping(to: crop) else { return }
            DispatchQueue.main.async { [self] in
                // 只在这个块仍是当前块时才更新，避免旧块覆盖新块
                if self.currentBlock == wantBlock {
                    self.blockImage = block
                    self.loadedBlock = wantBlock
                }
            }
        }
    }

    /// 读取大地图（11264²）的**降采样显示版**（边长 = displayMapSide，≈ 1/4 整图）。
    /// 小地图只在 220pt 小窗里显示当前块，整图 508MB 全分辨率解码纯属浪费内存
    /// （11264² RGBA ≈ 508MB，解码后常驻；降至 2816² ≈ 32MB，16 倍降幅，
    /// 220pt 显示下人眼不可分辨）。用 ImageIO 缩略解码，只解码一次并缓存。
    private static func loadDisplayMap() -> CGImage? {
        let path = "/Users/dupi/Desktop/自动驾驶系统/models/bigworldmapSecond.png"
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: displayMapSide,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// 显示图边长（整图 11264 的 1/4；每块 ≈ 352²，220pt 显示足够清晰）
    static let displayMapSide: CGFloat = 2816
}

/// 线程安全的降采样显示图缓存：后台只解码一次，避免重复+主线程解码
private final class MinimapBlockCache: @unchecked Sendable {
    static let shared = MinimapBlockCache()
    private let lock = NSLock()
    private var _display: CGImage? = nil
    func display() -> CGImage? { lock.lock(); defer { lock.unlock() }; return _display }
    func setDisplay(_ img: CGImage?) { lock.lock(); defer { lock.unlock() }; _display = img }
}

/// 定位门闩：把"是否正在定位"放在锁盒里，主线程 tryBegin/后台 end 均线程安全，
/// 避免 in-progress 标志在 @MainActor 与非隔离后台间的 actor 标注歧义。
final class LocateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    /// 尝试占用；已被占用则返回 false（本帧跳过）
    func tryBegin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }
    func end() { lock.lock(); defer { lock.unlock() }; busy = false }
    /// 当前是否在忙（诊断：持续 true = 定位任务积压/被饿，8Hz 调度被 gate 挡掉）
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }
}

/// 定位上下文：把只在后台定位队列使用的 VizardLocator 实例放进 Sendable 盒子，
/// 作为「let 存放的 Sendable 属性」跨线程访问（与 LocateGate 同理），避免 actor 标注歧义。
final class LocateContext: @unchecked Sendable {
    var visualLocator: VisualLocator? = nil
    var locatorReady = false
}