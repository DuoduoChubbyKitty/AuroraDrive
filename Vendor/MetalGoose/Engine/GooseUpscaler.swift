// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later
//
// GooseUpscaler — public integration façade for AuroraDrive.
//
// The upstream-vendored `GooseEngine` (GooseEngine.swift) is kept byte-for-byte
// with its members declared `internal` (its original module-internal API).
// This thin, documented wrapper lives in the same `MetalGooseEngine` module and
// re-exposes the minimal surface AuroraDrive needs — `make` / `attachToView` /
// `detachFromView` / `ingest` — as `public`, without patching the vendored source.
//
// Architecture note: frames fed here travel ONLY on the display / overlay path.
// The capture → CoreML inference → key-injection decision chain is never touched
// by this engine (see project NOTICE for the latency-red-line rationale).

import Foundation
import MetalKit

public final class GooseUpscaler {
    private let engine: GooseEngine

    private init(engine: GooseEngine) {
        self.engine = engine
    }

    /// Create a GooseEngine instance (forwards to the internal factory).
    public static func make() -> GooseUpscaler? {
        guard let e = GooseEngine.make() else { return nil }
        return GooseUpscaler(engine: e)
    }

    /// Bind the engine to a host MTKView for on-screen super-res / frame-gen.
    public func attachToView(_ view: MTKView, displayRefreshRate: Int = 60, minRefreshRate: Int = 30) {
        engine.attachToView(view, displayRefreshRate: displayRefreshRate, minRefreshRate: minRefreshRate)
    }

    /// Detach from the MTKView and release GPU resources.
    public func detachFromView() {
        engine.detachFromView()
    }

    /// Push one captured frame (CGImage) into the engine for processing.
    public func ingest(cgImage: CGImage, timestamp: CFTimeInterval = CACurrentMediaTime()) {
        engine.ingest(cgImage: cgImage, timestamp: timestamp)
    }

    /// Enable the MGFG-1 frame-interpolation pipeline (2x, display path only).
    ///
    /// Goes through the vendored engine's own settings surface (`updateSettings`)
    /// — it does not touch any vendored source. Interpolation holds back one
    /// captured frame, so it adds a full capture interval of latency; callers
    /// must only ever use this on the human-facing display/overlay path, never
    /// in the capture → inference → key-injection decision chain.
    public func configureInterpolation() {
        let settings = CaptureSettings.shared
        settings.scalingType = .off          // 只插帧，不做空间超分
        settings.aaMode = .off
        settings.frameGenMode = .interpolation
        settings.frameGenMultiplier = 2      // MetalFX 插帧固定 2x
        engine.updateSettings(settings)
    }

    /// 插帧引擎只读统计快照（诊断用）：确认插帧确实在产出中间帧。
    /// interpolatedFrameCount 持续增长 = 插帧工作；outputFPS 应 ≈ 捕获帧率 × 2。
    public struct GooseUpscalerStats {
        public let outputFrameCount: UInt64
        public let interpolatedFrameCount: UInt64
        public let passthroughFrameCount: UInt64
        public let generatedFrameCount: UInt64
        public let outputFPS: Float
        public let captureFPS: Float
    }

    public func statsSnapshot() -> GooseUpscalerStats {
        let s = engine.stats
        return GooseUpscalerStats(
            outputFrameCount: s.outputFrameCount,
            interpolatedFrameCount: s.interpolatedFrameCount,
            passthroughFrameCount: s.passthroughFrameCount,
            generatedFrameCount: s.generatedFrameCount,
            outputFPS: s.outputFPS,
            captureFPS: s.captureFPS
        )
    }

    /// 取出一条尚未上报的引擎错误（如 MG-ENG-010 MetalFX 插值器创建失败）。
    /// UpdateSettings 记录到引擎后再由主线程消费，显式暴露"插帧为何静默不产帧"的根因。
    /// 无错误返回 nil。
    public func pendingError() -> String? {
        engine.consumePendingError()
    }
}
