import AppKit

/// 云游戏「真实浏览器」启动器。
///
/// 【为什么不再用内置 WKWebView】实测 WKWebView 打开云游戏网页时：
///   ① ScreenCaptureKit 抓该窗口拿不到游戏画面；② 合成键盘/鼠标事件不被网页接受
///   （焦点 / Pointer Lock 问题）。所以改为用系统真实浏览器打开，再抓浏览器窗口 ——
///   真实浏览器窗口可被屏幕捕获，也能正常接收系统级按键注入。
/// 【优先级】按用户实测结论：优先 Google Chrome（更标准、`--app` 无地址栏最像 App），
///   没有 Chrome 再退回 Safari。
enum BrowserLauncher {
    static let cloudGameURL = URL(string: "https://yh.wanmei.com/cloud/")!

    struct Browser {
        let bundleID: String
        let appURL: URL
        let name: String
    }

    /// 自动发现已安装浏览器：Chrome 优先，Safari 兜底；都没有返回 nil。
    static func preferredBrowser() -> Browser? {
        let candidates: [(bundleID: String, name: String)] = [
            ("com.google.Chrome", "Google Chrome"),
            ("com.apple.Safari", "Safari"),
        ]
        for c in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: c.bundleID) {
                return Browser(bundleID: c.bundleID, appURL: url, name: c.name)
            }
        }
        return nil
    }

    /// 用指定浏览器打开云游戏并置前，返回其 NSRunningApplication（尽力，可能 nil）。
    @discardableResult
    static func openCloudGame(_ url: URL, browser: Browser) async throws -> NSRunningApplication {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if browser.bundleID == "com.google.Chrome" {
            // `--app=<url>`：Chrome 的「应用模式」——无标签栏/地址栏，看起来就像一个独立 App。
            // 让 Chrome 应用窗口铺满主屏：--app 默认用很小的默认尺寸，云游戏会占不满屏。
            // 同时给 --start-maximized 和显式 --window-size/--window-position，双保险。
            let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let w = Int(screen.width), h = Int(screen.height)
            config.createsNewApplicationInstance = true
            config.arguments = ["--app=\(url.absoluteString)", "--window-size=\(w),\(h)",
                                "--window-position=0,0", "--start-maximized"]
            return try await NSWorkspace.shared.openApplication(at: browser.appURL, configuration: config)
        }
        return try await NSWorkspace.shared.open([url], withApplicationAt: browser.appURL, configuration: config)
    }

    static func gameWindows(in windows: [CapturableWindow], browserBundleID: String,
                            browserPID: pid_t?, excluding existing: Set<CGWindowID> = []) -> [CapturableWindow] {
        let pool = windows.filter {
            $0.bundleIdentifier == browserBundleID && $0.width >= 640 && $0.height >= 360
                && (browserPID == nil || $0.ownerPID == browserPID)
        }
        let titled = pool.filter { hasGameTitle($0.title) }
        let newTitled = titled.filter { !existing.contains($0.id) }
        return newTitled.isEmpty ? titled : newTitled
    }

    static func launchedWindow(in windows: [CapturableWindow], browserBundleID: String,
                               browserPID: pid_t, frontWindowID: CGWindowID?,
                               existing: Set<CGWindowID>, allowReuse: Bool) -> CapturableWindow? {
        let candidates = windows.filter {
            $0.bundleIdentifier == browserBundleID && $0.ownerPID != nil
                && $0.width >= 640 && $0.height >= 360
        }
        let newWindows = candidates.filter { !existing.contains($0.id) }
        // Chrome can hand --app off to its already running process.
        if let front = newWindows.first(where: { $0.id == frontWindowID }),
           hasGameTitle(front.title)
            || (browserBundleID == "com.google.Chrome" && newWindows.count == 1) {
            return front
        }
        let newGameWindows = newWindows.filter { hasGameTitle($0.title) }
        let launched = newGameWindows.filter { $0.ownerPID == browserPID }
        if launched.count == 1 { return launched.first }
        if newGameWindows.count == 1 { return newGameWindows.first }
        guard allowReuse, newWindows.isEmpty else { return nil }
        return candidates.first { $0.id == frontWindowID && hasGameTitle($0.title) }
    }

    static func isSameWindow(_ lhs: CapturableWindow, _ rhs: CapturableWindow) -> Bool {
        lhs.id == rhs.id && lhs.ownerPID != nil && lhs.ownerPID == rhs.ownerPID
            && lhs.bundleIdentifier == rhs.bundleIdentifier
    }

    static func hasGameTitle(_ title: String) -> Bool {
        title.contains("异环") || title.contains("云游戏") || title.localizedCaseInsensitiveContains("wanmei")
    }
}
