// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import CoreFoundation
import Observation
import CoreVideo

@Observable
final class RecordEngine {

    // MARK: - 录制参数

    let targetSize = CGSize(width: 640, height: 360)

    let targetFps: Double = 24

    let maxClipsPerKind = 10

    // MARK: - 字模模式

    var glyphMode = false

    private var glyphRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("data")
            .appendingPathComponent("glyph_clips")
    }

    // MARK: - 状态

    private(set) var isRecording = false

    private(set) var frameCount: Int = 0

    private(set) var sessionURL: URL?

    private var startTime: Date?

    // MARK: - 内部资源

    private let writeQueue = DispatchQueue(label: "com.aurora.record.write")

    private static let maxPendingWrites = 1

    private let pendingLock = NSLock()
    private var pendingWrites: Int = 0

    private var csvHandle: FileHandle?

    private let dirFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private var recordingsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("data")
            .appendingPathComponent("raw_clips")
    }

    // MARK: - 录制控制

    func start(perspective: String = "first") {
        guard !isRecording else { return }

        pruneOldClips(in: recordingsRoot)
        pruneOldClips(in: glyphRoot)

        if glyphMode {
            try? FileManager.default.createDirectory(at: glyphRoot,
                                                     withIntermediateDirectories: true)
            let dirName = "clip_\(dirFormatter.string(from: Date()))"
            let sessionDir = glyphRoot.appendingPathComponent(dirName)
            let framesDir = sessionDir.appendingPathComponent("frames")
            try? FileManager.default.createDirectory(at: framesDir,
                                                     withIntermediateDirectories: true)
            sessionURL = sessionDir
            startTime = Date()
            frameCount = 0
            isRecording = true
            return
        }

        try? FileManager.default.createDirectory(at: recordingsRoot,
                                                 withIntermediateDirectories: true)
        let dirName = "clip_\(dirFormatter.string(from: Date()))"
        let sessionDir = recordingsRoot.appendingPathComponent(dirName)
        let framesDir = sessionDir.appendingPathComponent("frames")
        try? FileManager.default.createDirectory(at: framesDir,
                                                 withIntermediateDirectories: true)

        let viewLabel = (perspective == "first") ? "FPV" : "TPV"
        try? viewLabel.write(to: sessionDir.appendingPathComponent("view.txt"),
                             atomically: true, encoding: .utf8)

        let csvURL = sessionDir.appendingPathComponent("controls.csv")
        let header = "t_sec,frame,steer,throttle,brake\n"
        FileManager.default.createFile(atPath: csvURL.path,
                                       contents: header.data(using: .utf8))
        csvHandle = FileHandle(forWritingAtPath: csvURL.path)
        csvHandle?.seekToEndOfFile()

        sessionURL = sessionDir
        startTime = Date()
        frameCount = 0
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false

        // P1修复：先flush+关闭CSV句柄再判guard，防旧代码guard提前return漏关句柄（fd泄漏）

        if csvHandle != nil {
            writeQueue.sync {
                self.csvHandle?.synchronizeFile()
                self.csvHandle?.closeFile()
                self.csvHandle = nil
            }
        }

        guard let url = sessionURL,
              let start = startTime else { return }
        let totalFrames = frameCount
        let duration = Date().timeIntervalSince(start)

        if glyphMode {
            writeQueue.async { [isoFormatter] in
                let meta: [String: Any] = [
                    "glyph_mode": true,
                    "total_frames": totalFrames,
                    "created_at": isoFormatter.string(from: start),
                    "duration_seconds": duration,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: meta,
                                                          options: [.prettyPrinted]) {
                    try? data.write(to: url.appendingPathComponent("meta.json"))
                }
            }
            return
        }

        let size = targetSize
        let fps = targetFps
        let perspective = url.lastPathComponent
            .components(separatedBy: "_").first ?? "unknown"

        writeQueue.async { [isoFormatter] in
            let meta: [String: Any] = [
                "capture_interval_ms": Int(1000.0 / fps),
                "target_h": Int(size.height),
                "target_w": Int(size.width),
                "total_frames": totalFrames,
                "created_at": isoFormatter.string(from: start),
                "duration_seconds": duration,
                "perspective": perspective
            ]
            if let data = try? JSONSerialization.data(withJSONObject: meta,
                                                     options: [.prettyPrinted]) {
                try? data.write(to: url.appendingPathComponent("meta.json"))
            }
        }
    }

    // MARK: - 磁盘清理

    private func pruneOldClips(in root: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return }
        let clipDirs = entries
            .filter { $0.lastPathComponent.hasPrefix("clip_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard clipDirs.count > maxClipsPerKind else { return }
        for dir in clipDirs.prefix(clipDirs.count - maxClipsPerKind) {
            try? fm.removeItem(at: dir)
        }
    }

    // MARK: - 帧追加（主线程调用）

    private func nextFrameIndex() -> Int? {
        pendingLock.lock()
        let pending = pendingWrites
        pendingLock.unlock()
        guard pending <= Self.maxPendingWrites else { return nil }
        let idx = frameCount; frameCount += 1
        pendingLock.lock(); pendingWrites += 1; pendingLock.unlock()
        return idx
    }

    func appendFrame(image: NSImage, steer: Double, throttle: Double, brake: Double) {
        guard isRecording, let start = startTime, let url = sessionURL else { return }
        let timestamp = CFAbsoluteTimeGetCurrent() - (start.timeIntervalSinceReferenceDate)
        guard let idx = nextFrameIndex() else { return }

        writeQueue.async { [weak self, image] in
            defer {
                self?.pendingLock.lock()
                self?.pendingWrites -= 1
                self?.pendingLock.unlock()
            }
            guard let self else { return }

            // P1修复：NSImage缩放/编码产生大量临时对象，闭包不自动包池；背压多帧叠加放大峰值内存

            autoreleasepool {
                guard let jpgData = self.resizeAndEncodeJPEG(image: image, size: self.targetSize) else { return }
                let frameURL = url.appendingPathComponent("frames")
                    .appendingPathComponent(String(format: "%06ld.jpg", idx))
                try? jpgData.write(to: frameURL)
            }

            let line = String(format: "%.4f,%ld,%.4f,%.4f,%.4f\n",
                              timestamp, Int(idx), steer, throttle, brake)
            if let data = line.data(using: .utf8),
               data.count > 0 {
                self.csvHandle?.write(data)
            }
        }
    }

    func appendGlyphNative(pixelBuffer: CVPixelBuffer) {
        guard isRecording, let url = sessionURL else { return }
        guard let idx = nextFrameIndex() else { return }

        writeQueue.async { [weak self, pixelBuffer] in
            defer {
                self?.pendingLock.lock()
                self?.pendingWrites -= 1
                self?.pendingLock.unlock()
            }
            guard let self else { return }
            if let pngData = self.encodeNativePNG(pixelBuffer: pixelBuffer) {
                let frameURL = url.appendingPathComponent("frames")
                    .appendingPathComponent(String(format: "%06ld.png", idx))
                try? pngData.write(to: frameURL)
            }
        }
    }

    // MARK: - 画面缩放与编码

    private func resizeAndEncodeJPEG(image: NSImage, size: CGSize) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil,
                                          context: nil,
                                          hints: nil) else { return nil }

        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))

        guard let outImage = context.makeImage() else { return nil }

        let bitmapRep = NSBitmapImageRep(cgImage: outImage)
        return bitmapRep.representation(using: .jpeg,
                                         properties: [NSBitmapImageRep.PropertyKey.compressionFactor: 0.9])
    }

    // MARK: - 字模模式：原生 ROI 编码

    private func encodeNativePNG(pixelBuffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0 else { return nil }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else { return nil }
        guard let cg = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}
