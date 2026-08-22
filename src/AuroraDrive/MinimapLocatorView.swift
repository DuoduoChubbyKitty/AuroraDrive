// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import CoreGraphics
import ImageIO

struct MinimapLocatorView: View {
    @Bindable var state: DriveState

    static let mapSide: Double = 11264
    static let blocksPerEdge = 8
    static let blockSide: Double = mapSide / Double(blocksPerEdge)

    private let viewSize: CGFloat = 220

    @State private var blockImage: CGImage? = nil
    @State private var loadedBlock: Int = -1
    private let blockQueue = DispatchQueue(label: "aurora.minimap.block", qos: .userInitiated)

    private var currentBlock: Int {
        let bx = min(Self.blocksPerEdge - 1, max(0, Int(state.locatorX / Self.blockSide)))
        let by = min(Self.blocksPerEdge - 1, max(0, Int(state.locatorY / Self.blockSide)))
        return by * Self.blocksPerEdge + bx
    }

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
                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                        .position(x: relX * viewSize, y: relY * viewSize)
                }

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

            if state.locatorFound {
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

    private var originX: Double {
        Double(currentBlock % Self.blocksPerEdge) * Self.blockSide
    }
    private var originY: Double {
        Double(currentBlock / Self.blocksPerEdge) * Self.blockSide
    }

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
            let scale = CGFloat(src.width) / CGFloat(Self.mapSide)
            let crop = CGRect(x: desiredX * Double(scale),
                              y: desiredY * Double(scale),
                              width: Self.blockSide * Double(scale),
                              height: Self.blockSide * Double(scale))
            guard let block = src.cropping(to: crop) else { return }
            DispatchQueue.main.async { [self] in
                if self.currentBlock == wantBlock {
                    self.blockImage = block
                    self.loadedBlock = wantBlock
                }
            }
        }
    }

    private static func loadDisplayMap() -> CGImage? {
        let path = {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("models/bigworldmapSecond.png").path
        }()
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: displayMapSide,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static let displayMapSide: CGFloat = 2816
}

private final class MinimapBlockCache: @unchecked Sendable {
    static let shared = MinimapBlockCache()
    private let lock = NSLock()
    private var _display: CGImage? = nil
    func display() -> CGImage? { lock.lock(); defer { lock.unlock() }; return _display }
    func setDisplay(_ img: CGImage?) { lock.lock(); defer { lock.unlock() }; _display = img }
}

final class LocateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    func tryBegin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }
    func end() { lock.lock(); defer { lock.unlock() }; busy = false }
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }
}

final class LocateContext: @unchecked Sendable {
    var visualLocator: VisualLocator? = nil
    var networkLocator: NetworkLocator? = nil
    var visualReady = false
    var networkReady = false
    var activeMode = "fallback"
}
