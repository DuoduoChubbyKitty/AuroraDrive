import AppKit
import WebKit

@MainActor
final class CloudGameWindow: NSObject, WKUIDelegate, NSWindowDelegate {
    static let identifier = "AuroraCloudGame"
    static let gameURL = URL(string: "https://yh.wanmei.com/cloud/")!
    private var main: NSWindow?
    private var webView: WKWebView?
    private var popups: [NSWindow] = []

    /// 当前云游戏窗口号（未打开为 nil）。供「驾驶时置前」判断采集目标是否是它。
    var windowNumber: Int? { main?.windowNumber }

    /// 是否已经是系统 key window（键盘事件当前会落到它）。
    var isKey: Bool { main?.isKeyWindow ?? false }

    /// 重新主张 key window + 第一响应者（不切换 App 时也能把键盘焦点拉回云窗）。
    func reassertKey() {
        guard let main else { return }
        NSApp.activate(ignoringOtherApps: true)
        main.makeKeyAndOrderFront(nil)
        if let webView { _ = main.makeFirstResponder(webView) }
    }

    /// 把云游戏窗口置前、设为 key window 并把第一响应者交给 WKWebView。
    /// 【为什么需要】按键注入走全局 `.cghidEventTap`，只会送到**最前台 App 的焦点窗口**；
    /// 云游戏是本 App 自己的 WKWebView 窗口，若不主动置前，注入会落到主控制台窗口上，
    /// 表现就是「UI 显示在发键、游戏不动」。仅在开始驾驶时调用一次。
    func focusForInput() {
        guard let main else { return }
        NSApp.activate(ignoringOtherApps: true)
        main.makeKeyAndOrderFront(nil)
        if let webView { _ = main.makeFirstResponder(webView) }
        // 让网页里的 document 也拿到焦点（部分云游戏 canvas 需要 window 焦点才收 keydown）。
        webView?.evaluateJavaScript("try{window.focus&&window.focus()}catch(e){}")
    }

    func open() -> CGWindowID {
        if let main {
            main.makeKeyAndOrderFront(nil)
            return CGWindowID(main.windowNumber)
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        let view = WKWebView(frame: .zero, configuration: config)
        let window = makeWindow(view, title: "异环云游戏", size: NSSize(width: 1280, height: 720))
        main = window
        view.load(URLRequest(url: Self.gameURL))
        return CGWindowID(window.windowNumber)
    }

    private func makeWindow(_ view: WKWebView, title: String, size: NSSize) -> NSWindow {
        webView = view
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(Self.identifier)
        window.tabbingMode = .disallowed
        window.title = title
        window.contentView = view
        window.delegate = self
        view.uiDelegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        return window
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popups.append(makeWindow(popup, title: "异环云游戏", size: NSSize(width: 800, height: 640)))
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) { webView.window?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === main {
            main = nil
            webView = nil
            for popup in popups { popup.close() }
        } else {
            popups.removeAll { $0 === window }
        }
    }
}
