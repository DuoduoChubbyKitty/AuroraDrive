// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  AuroraBrand.swift — 品牌常量与 logo 定位（唯一品牌事实源）
// ============================================================================
//
//  【为什么需要这个文件】
//  用户原话：「你给我写的什么 MAA 都来了，**是我们的牌子吗？是我们头像吗？**」
//            「他妈的 logo 都给你改成不是我们的了」。
//  背景：地图预览站里那张 `public/logo.png` 是一张**红发狐娘插画**——既不是
//  我们的牌子，也不是我们画的。App 侧此前也**没有任何品牌常量**：窗口标题、
//  名称、logo 路径散落在各处或干脆不存在。
//
//  本文件是**品牌的唯一事实源**：任何要显示名字/标题/logo 的地方都从这里取，
//  不许再各自硬编码字符串。这样"换牌子"永远只改这一个文件。
//
//  【契约（port-ui 依赖，勿改签名）】
//      AuroraBrand.nameCN        → "AuroraDrive 异环驾驶地图"
//      AuroraBrand.windowTitle   → "AuroraDrive 地图"
//      AuroraBrand.logoName      → "AuroraLogo"
//      AuroraBrand.logoURL()     → URL?（logo PNG 的实际位置）
//
//  【logo 定位为什么要多候选】
//  本项目有**四种**运行形态，工作目录各不相同：
//    · `swift run` / 从 shell 直接跑二进制 → cwd = 项目根
//    · `open AuroraDriveUI.app`（双击）    → cwd = "/"，且 Bundle 是 .app
//    · 引擎子进程（`--engine`）            → cwd 继承父进程
//    · 各种 `--xxx-selftest` 一次性进程     → cwd 不确定
//  单靠 `Bundle.main` 或单靠 cwd 都会在某一形态下失效。故按优先级逐个试，
//  第一个真实存在且非空的胜出。这与 `AuroraPaths.projectRoot()` 的多候选
//  思路一致（那个文件解决的是"项目根在哪"，本文件解决的是"logo 在哪"）。
//
//  【解析只做一次】
//  `resolvedLogoURL` 是 `static let` → Swift 用 `swift_once` 保证**线程安全
//  且只求值一次**。UI body 里每帧调 `logoURL()` 也只是读一个已算好的可选值，
//  不碰文件系统（对照：`AuroraPaths.cachedRoot` 是手写缓存，首访有竞争窗口；
//  这里直接用语言保证，不重复那个坑）。
// ============================================================================

import AppKit
import Foundation

enum AuroraBrand {

    // MARK: - 名称（契约字段）

    /// 中文全名（关于页 / 窗口标题栏 / 截图水印）
    static let nameCN = "AuroraDrive 异环驾驶地图"

    /// 地图窗口标题
    static let windowTitle = "AuroraDrive 地图"

    /// logo 资源基名（不含扩展名）。文件名 = `<logoName>.png`
    static let logoName = "AuroraLogo"

    // MARK: - 名称（配套字段，非契约但同样唯一）

    /// 英文/短名（菜单栏、Dock、日志前缀用；与 Info.plist 的 CFBundleName 一致）
    static let nameEN = "AuroraDrive"

    /// 一句话定位（关于页副标题）
    static let tagline = "实时游戏驾驶辅助 · 地图 · 感知 · 决策"

    /// 版权行
    static let copyright = "© 2026 DuoduoChubbyKitty · GPL-3.0-or-later"

    // MARK: - logo 定位

    /// logo 的候选路径，**按优先级排列**。
    ///
    /// 顺序理由：
    ///   ① `Resources/`（项目根）—— 开发期与 shell 启动的主路径，也是
    ///      `tools/map/brand/make_logo.py` 的默认输出位置；
    ///   ② Bundle 的 resourceURL 根 —— 打包成 .app 后若把 PNG 拷进
    ///      `Contents/Resources/`，这里命中；
    ///   ③ Bundle 内再套一层 `Resources/` —— 对应 `Contents/Resources/Resources/`
    ///      这种"原样拷贝目录"的打包方式；
    ///   ④ `Bundle.url(forResource:)` —— 标准资源查找（含本地化子目录）；
    ///   ⑤ 可执行文件同级 —— `open` 双击启动、cwd 是 "/" 时的兜底；
    ///   ⑥ cwd —— 最后兜底。
    private static func candidates() -> [URL] {
        var out: [URL] = []
        let file = "\(logoName).png"

        // ① 项目根 / Resources
        out.append(AuroraPaths.projectRoot()
            .appendingPathComponent("Resources")
            .appendingPathComponent(file))

        // ② / ③ Bundle 资源目录
        if let res = Bundle.main.resourceURL {
            out.append(res.appendingPathComponent(file))
            out.append(res.appendingPathComponent("Resources").appendingPathComponent(file))
        }

        // ④ 标准资源查找
        if let u = Bundle.main.url(forResource: logoName, withExtension: "png") {
            out.append(u)
        }

        // ⑤ 可执行文件同级
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            out.append(exeDir.appendingPathComponent(file))
            out.append(exeDir.appendingPathComponent("Resources").appendingPathComponent(file))
        }

        // ⑥ cwd
        out.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources")
            .appendingPathComponent(file))

        return out
    }

    /// 真正做一次文件系统探测。**只被 `resolvedLogoURL` 调用一次。**
    ///
    /// 判据用「存在 + 是常规文件 + 字节数 > 0」三条：
    /// 只判存在的话，一个 0 字节的占位文件会被当成有效 logo，
    /// 而 `NSImage(contentsOf:)` 对它返回 nil —— 症状是"图标位置一片空白"
    /// 却查不出原因。宁可在解析阶段就把它跳过。
    private static func resolveLogoURL() -> URL? {
        let fm = FileManager.default
        for url in candidates() {
            guard fm.fileExists(atPath: url.path) else { continue }
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile ?? false
            guard isFile else { continue }
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            guard let bytes = size, bytes > 0 else { continue }
            return url
        }
        return nil
    }

    /// logo PNG 的实际位置；`nil` = 四个候选都没命中（此时调用方应显示文字兜底，
    /// **不要**画一个空白方块）。
    ///
    /// `static let` → 线程安全 + 全生命周期只解析一次（见文件头说明）。
    private static let resolvedLogoURL: URL? = resolveLogoURL()

    static func logoURL() -> URL? { resolvedLogoURL }

    /// 32×32 小图（标题栏/列表项用）。不存在则返回 nil，调用方回退到主图缩放。
    private static let resolvedLogoSmallURL: URL? = {
        guard let main = resolvedLogoURL else { return nil }
        let small = main.deletingLastPathComponent()
            .appendingPathComponent("\(logoName)-32.png")
        return FileManager.default.fileExists(atPath: small.path) ? small : nil
    }()

    static func logoSmallURL() -> URL? { resolvedLogoSmallURL }

    /// logo 是否可用（UI 据此决定显示图标还是文字兜底）
    static var hasLogo: Bool { resolvedLogoURL != nil }

    // MARK: - 便捷加载（给 SwiftUI / AppKit 用）

    /// 加载 logo 为 `NSImage`。`nil` = 未找到或解码失败。
    ///
    /// ⚠️ 不缓存 `NSImage`：`NSImage` 不是线程安全的，且 SwiftUI 会自己缓存
    /// 渲染结果。调用方若在热路径上反复取用，请自行持有。
    static func logoImage() -> NSImage? {
        guard let url = resolvedLogoURL else { return nil }
        return NSImage(contentsOf: url)
    }

    /// 小图（优先 32px 专用文件，缺失则用主图）。
    static func logoSmallImage() -> NSImage? {
        if let small = resolvedLogoSmallURL, let img = NSImage(contentsOf: small) {
            return img
        }
        return logoImage()
    }

    // MARK: - 自检

    /// 品牌自检：返回逐行结果，`ok == false` 表示有硬失败。
    ///
    /// 为什么要有：logo 定位跨 4 种运行形态，**任何单一环境下的"我看到图了"
    /// 都不构成验证**（双击启动时 cwd="/"，从 shell 跑时 cwd=项目根，
    /// 两者命中不同候选）。把"到底命中了哪个候选、文件多大、能不能解码、
    /// 尺寸对不对"打成可核对的文本，才不会重蹈"图标空白但查不出原因"。
    ///
    /// 用法（任选其一，本函数不做 IO 之外的副作用）：
    ///     print(AuroraBrand.selfCheckLines().joined(separator: "\n"))
    static func selfCheckLines() -> [String] {
        var lines: [String] = []
        var ok = true

        lines.append("═══ 品牌自检 ═══")
        lines.append("  名称: \(nameCN)")
        lines.append("  窗口标题: \(windowTitle)")
        lines.append("  logo 基名: \(logoName)")

        lines.append("── 候选路径探测 ──")
        let fm = FileManager.default
        var hitIndex = -1
        for (i, url) in candidates().enumerated() {
            let exists = fm.fileExists(atPath: url.path)
            let bytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            let mark = exists ? "✓" : "·"
            let sizeText = bytes.map { "\($0) B" } ?? "-"
            lines.append("  \(mark) [\(i)] \(url.path)  \(sizeText)")
            if exists, hitIndex < 0 { hitIndex = i }
        }

        lines.append("── 解析结果 ──")
        if let url = logoURL() {
            lines.append("  ✓ logoURL() 命中候选 [\(hitIndex)]: \(url.path)")
            let bytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            if let b = bytes, b > 0 {
                lines.append("  ✓ 文件非空: \(b) B")
            } else {
                lines.append("  ✗ 文件为空"); ok = false
            }
            if let img = logoImage() {
                let px = img.representations.first.map {
                    "\($0.pixelsWide)×\($0.pixelsHigh)"
                } ?? "未知"
                lines.append("  ✓ NSImage 解码成功，像素 \(px)")
                let w = img.representations.first?.pixelsWide ?? 0
                if w == 1024 {
                    lines.append("  ✓ 主图尺寸 = 1024（契约值）")
                } else {
                    lines.append("  ⚠️ 主图尺寸 \(w) ≠ 1024（契约值）—— 不致命，但请核对")
                }
            } else {
                lines.append("  ✗ NSImage 解码失败"); ok = false
            }
        } else {
            lines.append("  ✗ logoURL() == nil：所有候选都没命中")
            lines.append("     修复：跑 python3 tools/map/brand/make_logo.py 生成 Resources/AuroraLogo.png")
            ok = false
        }

        if let small = logoSmallURL() {
            lines.append("  ✓ 32px 小图: \(small.lastPathComponent)")
        } else {
            lines.append("  · 32px 小图缺失（调用方会回退到主图缩放，非致命）")
        }

        lines.append(ok ? "═══ 品牌自检：PASS ═══" : "═══ 品牌自检：FAIL ═══")
        return lines
    }
}
