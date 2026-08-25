// PostBuildSignPlugin.swift
// SwiftPM Build Tool Plugin: 编译后自动签名 + 复制到项目根目录，
// 并额外构建 .app bundle 供 LaunchServices 启动。
//
// 为何要 .app bundle：裸可执行文件从子进程（如 TraeCode/Electron 的 RunCommand）
// 启动会被 taskgated 连坐父进程签名而 SIGKILL；.app bundle 经 LaunchServices
// 由 launchd 启动，父进程链干净，ad-hoc 签名可正常通过 AMFI 运行时校验。
// 根目录 AuroraDriveUI 裸文件保留，作为交付给终端/Finder 的可执行入口。

import PackagePlugin
import Foundation

@main struct PostBuildSignPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        // 只处理 AuroraDrive 可执行目标
        guard target.name == "AuroraDrive" else {
            return []
        }

        // SwiftPM release 编译产物固定路径：.build/release/AuroraDrive
        let config = "release"
        let execPath = context.package.directory
            .appending(".build")
            .appending(config)
            .appending(target.name)
            .string

        // 裸可执行文件交付路径：项目根目录 AuroraDriveUI
        let outputPath = context.package.directoryURL
            .appendingPathComponent("AuroraDriveUI")
            .path

        // 一次性脚本：签名源二进制 → 复制裸文件 → 构建+签名 .app bundle → 清 quarantine
        // Info.plist 用 printf 在脚本内直接写，避免依赖插件预写文件（pluginWorkDirectory
        // 在某些环境下不可写，会导致脚本 cp 失败、set -e 中断）。
        let script = """
            #!/bin/sh
            set -e
            BUNDLE_DIR="$(dirname "$2")/AuroraDriveUI.app"
            # 1) 签名源二进制（ad-hoc，满足 AMFI 运行时签名校验）
            /usr/bin/codesign --force --deep --sign - "$1"
            # 2) 裸可执行文件交付
            cp "$1" "$2"
            /usr/bin/xattr -d com.apple.quarantine "$2" 2>/dev/null || true
            # 3) .app bundle：mkdir → cp 二进制 → printf Info.plist → 签 bundle → 清 quarantine
            mkdir -p "$BUNDLE_DIR/Contents/MacOS"
            cp "$1" "$BUNDLE_DIR/Contents/MacOS/AuroraDriveUI"
            printf '%s\\n' \\
              '<?xml version="1.0" encoding="UTF-8"?>' \\
              '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \\
              '<plist version="1.0">' '<dict>' \\
              '<key>CFBundleExecutable</key><string>AuroraDriveUI</string>' \\
              '<key>NSPrincipalClass</key><string>NSApplication</string>' \\
              '<key>CFBundleIdentifier</key><string>com.aurora.driveui</string>' \\
              '<key>CFBundleName</key><string>AuroraDrive</string>' \\
              '<key>CFBundleDisplayName</key><string>AuroraDrive</string>' \\
              '<key>CFBundlePackageType</key><string>APPL</string>' \\
              '<key>CFBundleShortVersionString</key><string>1.0</string>' \\
              '<key>CFBundleVersion</key><string>1</string>' \\
              '<key>LSMinimumSystemVersion</key><string>14.0</string>' \\
              '<key>LSUIElement</key><false/>' \\
              '<key>NSHighResolutionCapable</key><true/>' \\
              '</dict>' '</plist>' > "$BUNDLE_DIR/Contents/Info.plist"
            /usr/bin/codesign --force --deep --sign - "$BUNDLE_DIR"
            /usr/bin/xattr -d com.apple.quarantine "$BUNDLE_DIR" 2>/dev/null || true
            # 清理同名残留进程：旧 AuroraDriveUI 进程在跑时，新 .app 经 LaunchServices
            # 启动会被判为"已运行"而不创建新窗口（实测：进程活但无窗口的根因）。
            /usr/bin/pkill -f "AuroraDriveUI" 2>/dev/null || true
            """

        let scriptPath = context.pluginWorkDirectoryURL
            .appendingPathComponent("sign_and_copy.sh")
            .path
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        return [
            .buildCommand(
                displayName: "Sign & Copy AuroraDrive → AuroraDriveUI (+ .app bundle)",
                executable: PackagePlugin.Path(scriptPath),
                arguments: [execPath, outputPath],
                environment: [:],
                inputFiles: [PackagePlugin.Path(execPath)],
                outputFiles: [PackagePlugin.Path(outputPath)]
            )
        ]
    }
}
