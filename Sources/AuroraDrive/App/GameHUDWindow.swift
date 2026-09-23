// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  GameHUDWindow.swift — 游戏画面左上角帧率 HUD（绿色字、两行对齐）
//
//  用途（双重）：
//   1) 实用：游戏全屏时实时显示「辅助帧率（AuroraDrive 处理帧率）」与
//      「游戏帧率（ScreenCaptureKit 实际捕获到的合成帧率）」两行数据，
//      用来判断 Game Mode 是否在压制本进程（掉到个位数 = 被压制）。
//   2) 对抗 Game Mode：一个持续可见的真实窗口比 1×1 隐形锚点更难被
//      gamepolicyd 归入「无可见窗口的纯后台」桶（Game Mode 会压制后台任务）。
//
//  关键实现：
//    · window level = .screenSaver —— 压过游戏全屏窗口
//    · collectionBehavior 含 .fullScreenAuxiliary —— 游戏进全屏 Space 后依然可见
//    · ignoresMouseEvents = true —— 绝不拦截游戏操作
//    · 绿色等宽字 + 半透明黑底 —— HUD 风格且在任何画面上可读
// ============================================================================

import AppKit

/// 帧率 HUD 浮层（游戏画面上方）
@MainActor
final class GameHUDWindow {

    private var window: NSWindow?
    private var label: NSTextField?
    private var updateTimer: Timer?

    /// 两行数据的取值闭包（由调用方提供，避免此处依赖具体引擎内部）
    var fpsProvider: (() -> (assist: Double, game: Double))?

    /// HUD 是否已安装
    var isInstalled: Bool { window != nil }
    /// 当前窗口可见性（诊断用）
    var debugState: String {
        guard let w = window else { return "未安装" }
        return "visible=\(w.isVisible) level=\(w.level.rawValue) frame=\(w.frame)"
    }

    /// 安装 HUD（幂等：重复调用只更新一次）
    /// - Parameter corner: 屏幕角（默认左上角，符合用户要求）
    func install() {
        if window != nil { return }
        // 自我保护：没有 NSApplication UI 上下文时绝不创建窗口。
        // 引擎进程（--engine）会创建 DriveState，若在其内建窗会崩 AppKit
        // （NSViewSetCurrentlyBuildingLayerTreeForDisplay assertion）。
        guard NSApp != nil else {
            print("[HUD] 无 NSApplication 上下文（引擎进程）→ 跳过 HUD 安装")
            return
        }

        // 尺寸：够放两行等宽字（HUD 小巧，避免遮挡游戏视野）
        let w: CGFloat = 168
        let h: CGFloat = 46
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.borderless],
                           backing: .buffered,
                           defer: false)
        // 标识为「有意创建的辅助窗口」：主窗口置前逻辑会跳过所有带此标识的窗口，
        // 避免把 HUD 误判成退化空壳而关掉。
        win.identifier = NSUserInterfaceItemIdentifier("AuroraAuxHUD")
        win.isOpaque = false
        win.backgroundColor = NSColor.black.withAlphaComponent(0.28)  // 半透明黑底，保证绿字可读
        win.hasShadow = false
        win.ignoresMouseEvents = true          // 绝不拦截游戏点击
        win.isMovable = false
        win.level = .screenSaver               // ★ 压过全屏游戏
        win.collectionBehavior = [.canJoinAllSpaces,
                                  .stationary,
                                  .ignoresCycle,
                                  .fullScreenAuxiliary]   // ★ 跟随游戏全屏 Space
        // 左上角内缩（用 CGDisplay 取主屏全尺寸，不受 app 激活状态影响）
        let b = CGDisplayBounds(CGMainDisplayID())
        win.setFrameOrigin(NSPoint(x: b.minX + 8, y: b.maxY - h - 8))

        // 绿色等宽两行
        let tf = NSTextField(labelWithString: "辅助帧率  --\n游戏帧率  --")
        tf.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        tf.textColor = NSColor(calibratedRed: 0.20, green: 1.0, blue: 0.35, alpha: 1.0)  // 荧光绿
        tf.backgroundColor = .clear
        tf.drawsBackground = false
        tf.isBordered = false
        tf.isEditable = false
        tf.isSelectable = false
        tf.alignment = .left
        tf.maximumNumberOfLines = 2
        tf.frame = NSRect(x: 6, y: 4, width: w - 12, height: h - 8)
        win.contentView?.addSubview(tf)

        win.orderFrontRegardless()
        window = win
        label = tf

        // 2Hz 刷新（HUD 数字不需要更快；低刷新也顺带减少自身唤醒）
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        updateTimer = t
        refresh()
    }

    /// 卸载（停止定时器并关窗）
    func uninstall() {
        updateTimer?.invalidate()
        updateTimer = nil
        window?.orderOut(nil)
        window = nil
        label = nil
    }

    /// 刷新两行文本（等宽对齐：左列标签同宽，右侧数字同宽）
    private func refresh() {
        guard let label, let provider = fpsProvider else { return }
        let v = provider()
        let a = v.assist >= 0 ? String(format: "%5.1f", v.assist) : "  -- "
        let g = v.game >= 0 ? String(format: "%5.1f", v.game) : "  -- "
        // 两行结构完全一致 → 天然左对齐
        label.stringValue = "辅助帧率 \(a)\n游戏帧率 \(g)"
    }
}
