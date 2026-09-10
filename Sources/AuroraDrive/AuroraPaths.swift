// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later
// 项目根定位：源码重组进 Sources/AuroraDrive/ 后，#filePath 不再指向项目根。
// 本文件提供统一的多候选根目录解析，供 models/data/recordings 等资源定位使用。

import Foundation

enum AuroraPaths {
    /// 解析结果缓存（进程内只需解析一次）
    nonisolated(unsafe) static var cachedRoot: URL?

    /// 定位项目根目录。按优先级尝试多个候选，取第一个能验证的（含 Package.swift 或 models/）。
    static func projectRoot() -> URL {
        if let cached = cachedRoot { return cached }

        var candidates: [URL] = []

        // 1. 本文件编译期路径上溯 3 级：Sources/AuroraDrive/Paths.swift → 项目根
        candidates.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent())

        // 2. 当前工作目录（从项目根手动启动时的常见情况）
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

        // 3. 可执行文件所在目录（双击 AuroraDriveUI 启动时 cwd 即此处）
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(execDir)
        }

        // 4. 已知安装位置（兜底）
        candidates.append(URL(fileURLWithPath: "/Users/dupi/Desktop/自动驾驶系统"))

        for c in candidates {
            let fm = FileManager.default
            if fm.fileExists(atPath: c.appendingPathComponent("Package.swift").path)
                || fm.fileExists(atPath: c.appendingPathComponent("models").path) {
                cachedRoot = c
                return c
            }
        }

        // 全部候选失败：回退第一个候选（调用方仍需处理资源缺失）
        cachedRoot = candidates[0]
        return candidates[0]
    }

    /// models/ 目录（CoreML 模型、字模库、地图资源）
    static func modelsDir() -> URL {
        projectRoot().appendingPathComponent("models")
    }

    /// data/ 目录（raw_clips / glyph_clips 训练数据）
    static func dataDir() -> URL {
        projectRoot().appendingPathComponent("data")
    }
}