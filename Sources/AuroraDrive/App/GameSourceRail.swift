import AppKit
import SwiftUI
import ApplicationServices
import UniformTypeIdentifiers

enum GameWindowFocus {
    static func isFocused(_ windowID: CGWindowID, pid: pid_t) -> Bool {
        // ⚠️ 2026-11-19 修复（用户报障：驾驶时永远显示「等待游戏切到前台」）：
        //   原实现要求「该进程 layer0 的**第一个**窗口号 == 采集窗口号」。
        //   Chrome --app 模式下同一 Chrome 进程有多个 layer0 窗口（app 窗 + 隐藏/辅助窗），
        //   CGWindowListCopyWindowInfo 的首个不一定是真正被采集的那个 → 恒 false → 误报。
        //   改为：前台 App 是该 pid，且采集窗口**存在于该进程的可见 layer0 窗口集合中**。
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        // 采集窗口仍存在且属于该 pid（窗口被关掉时这里会 false，语义不变）
        guard exists(windowID, pid: pid) else { return false }
        let onScreen = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        return (onScreen ?? []).contains {
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid)
                && ($0[kCGWindowLayer as String] as? Int) == 0
                && ($0[kCGWindowNumber as String] as? Int) == Int(windowID)
        }
    }

    private static func frontWindow(for pid: pid_t) -> [String: Any]? {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        return windows?.first { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid)
            && ($0[kCGWindowLayer as String] as? Int) == 0 }
    }

    static func foregroundWindowID(for bundleID: String) -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID,
              let id = frontWindow(for: app.processIdentifier)?[kCGWindowNumber as String] as? Int else { return nil }
        return CGWindowID(exactly: id)
    }

    static func browserWindows(_ browser: BrowserLauncher.Browser) -> [CapturableWindow] {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID)
            .map(\.processIdentifier))
        let ordered = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        return (ordered ?? []).compactMap { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let owner = window[kCGWindowOwnerPID as String] as? Int, let pid = pid_t(exactly: owner),
                  pids.contains(pid), let number = window[kCGWindowNumber as String] as? Int,
                  let id = CGWindowID(exactly: number),
                  let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  bounds.width >= 640, bounds.height >= 360 else { return nil }
            let title = window[kCGWindowName as String] as? String ?? ""
            return CapturableWindow(ownerPID: pid, id: id, applicationName: browser.name,
                                    bundleIdentifier: browser.bundleID, title: title,
                                    width: Int(bounds.width.rounded()), height: Int(bounds.height.rounded()),
                                    isGame: BrowserLauncher.hasGameTitle(title), isOwn: false)
        }
    }

    static func existingWindowIDs() -> Set<CGWindowID> {
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
        return Set((windows ?? []).compactMap {
            ($0[kCGWindowNumber as String] as? Int).flatMap(CGWindowID.init(exactly:))
        })
    }

    static func exists(_ windowID: CGWindowID, pid: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]]
        return (windows?.first?[kCGWindowOwnerPID as String] as? Int) == Int(pid)
    }

    @MainActor
    static func raise(_ target: CapturableWindow) {
        guard let pid = target.ownerPID,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        if pid == getpid() {
            NSApp?.windows.first { $0.windowNumber == Int(target.id) }?.makeKeyAndOrderFront(nil)
            return
        }
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, target.id) as? [[String: Any]]
        let bounds = (info?.first?[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        if #available(macOS 14.0, *) { NSApp?.yieldActivation(to: app) }
        app.activate(options: [])
        guard let bounds else { return }
        let accessibleApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(accessibleApp, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(accessibleApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        let matching = windows.filter { window in
            guard let point = geometry(window, kAXPositionAttribute, type: .cgPoint),
                  let size = geometry(window, kAXSizeAttribute, type: .cgSize) else { return false }
            return abs(point.x - bounds.minX) < 4 && abs(point.y - bounds.minY) < 4
                && abs(size.x - bounds.width) < 4 && abs(size.y - bounds.height) < 4
        }
        if matching.count == 1, let window = matching.first {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    private static func geometry(_ window: AXUIElement, _ attribute: String, type: AXValueType) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        if type == .cgSize {
            var size = CGSize.zero
            guard AXValueGetValue(axValue, type, &size) else { return nil }
            return CGPoint(x: size.width, y: size.height)
        }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, type, &point) else { return nil }
        return point
    }

    /// 把目标窗口用辅助功能 API 直接设成主屏**可见区域**大小并归位到 (0,0)。
    /// 【为什么需要】Chrome `--app` 的 `--window-size` 在把 URL 交给已运行的 Chrome
    ///   实例时经常被忽略（窗口用默认小尺寸），且单位是"点"未扣菜单栏 → 云游戏占不满屏。
    ///   这里在窗口出现后主动用 AX 设定位置/尺寸，可靠铺满。
    /// 【前置】调用方需有「辅助功能」授权（本项目驾驶本就需要，已有）。
    @MainActor
    static func maximizeToScreen(_ target: CapturableWindow) {
        guard let pid = target.ownerPID, pid != getpid() else { return }
        // 可见区域（扣掉菜单栏/Dock），y 原点即 menu bar 下方
        let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        // 用「当前 bounds 与之最接近」匹配出被采集的那个窗口（与 raise 同款比对）
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, target.id) as? [[String: Any]]
        let bounds = (info?.first?[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        let match = windows.first { window in
            guard let point = geometry(window, kAXPositionAttribute, type: .cgPoint),
                  let size = geometry(window, kAXSizeAttribute, type: .cgSize) else { return false }
            guard let bounds else { return false }
            return abs(point.x - bounds.minX) < 4 && abs(point.y - bounds.minY) < 4
                && abs(size.x - bounds.width) < 4 && abs(size.y - bounds.height) < 4
        }
        guard let win = match else { return }
        // AX 坐标系原点在主屏左上角（y 向下）；visibleFrame 原点在左下（y 向上）→ 换算
        let screenH = NSScreen.main?.frame.height ?? vis.maxY
        var pos = CGPoint(x: vis.minX, y: screenH - vis.maxY)
        var size = CGSize(width: vis.width, height: vis.height)
        if let posVal = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
        }
    }
}
@Observable @MainActor
final class GameLauncher {
    static let bundleID = "com.pwrd.yh.ios"
    private let cloudWindow = CloudGameWindow()
    let localSession = LocalGameSession()
    private let pathKey = "Aurora.localGamePath"
    private(set) var localURL: URL?
    private(set) var icon: NSImage?
    private(set) var busy = false
    var needsWindow = false
    var status = ""
    private(set) var choices: [CapturableWindow] = []
    private var lastFocusReassert = Date.distantPast
    /// 云游戏「真实浏览器窗口」的采集目标（window id + 所属浏览器 pid），用于聚焦/保持前台。
    private(set) var cloudTargetWindowID: CGWindowID?
    private(set) var cloudTargetAppPID: pid_t?
    private(set) var launchedCloudWindow: CapturableWindow?

    func discover() {
        let ws = NSWorkspace.shared
        // 外置盘优先：卷名含「游戏」的排前面，避免插了备份盘时选到旧副本。
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? [])
            .sorted { a, b in
                let an = a.lastPathComponent.contains("游戏"), bn = b.lastPathComponent.contains("游戏")
                return an && !bn
            }
        // 外置盘架构（见 ~/.yihuan/launch.sh）：正确实例是「去沙盒副本」异环_nosandbox.app；
        // 原版 异环.app 只是 prepare.sh 的源，经 LaunchServices 启动会注入 __CFBundleIdentifier
        // 把 UE 卡死。候选里 nosandbox 排前，仅供图标/选择展示；真正启动走下面的启动器。
        let installed = volumes.flatMap { vol -> [URL] in
            let base = vol.appendingPathComponent("Applications")
            return [base.appendingPathComponent("异环_nosandbox.app"),
                    base.appendingPathComponent("异环.app")]
        }
        let wrapper = Self.externalWrapperURL()
        let saved = UserDefaults.standard.string(forKey: pathKey).map(URL.init(fileURLWithPath:))
        let urls = [saved].compactMap { $0 }
            + [wrapper].compactMap { $0 }
            + installed
            + ws.urlsForApplications(withBundleIdentifier: Self.bundleID)
        localURL = urls.first { Bundle(url: $0)?.bundleIdentifier == Self.bundleID }
        icon = localURL.map { ws.icon(forFile: $0.path) }
    }

    /// 外置盘启动器 app（→ ~/.yihuan/launch.sh，会 `env -u` 掉 `__CFBundleIdentifier` 再拉起）。
    static func externalWrapperURL() -> URL? {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/异环（外置盘）.app")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// 云游戏窗口号（未打开为 nil）。
    var cloudWindowNumber: Int? { cloudWindow.windowNumber }

    /// 若当前采集目标是云游戏窗口（内置 WKWebView 或真实浏览器窗口），把它/它的浏览器置前。
    /// 按键注入是全局 `.cghidEventTap`（只送最前台焦点窗口），不置前就会打到控制台上。
    func focusIfCloudTarget(_ mode: CaptureMode) {
        guard case .window(let id) = mode else { return }
        if let target = cloudTargetWindowID, id == target {
            activateCloudBrowser()
        } else if Int(id) == cloudWindowNumber {
            cloudWindow.focusForInput()
        }
    }

    /// 驾驶/壳模式期间持续确保云游戏前台（每 0.5s 最多纠正一次）。
    func keepCloudFocus(_ mode: CaptureMode) {
        guard case .window(let id) = mode else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFocusReassert) > 0.5 else { return }
        if let target = cloudTargetWindowID, id == target {
            guard let pid = cloudTargetAppPID,
                  let app = NSRunningApplication(processIdentifier: pid), !app.isActive else { return }
            lastFocusReassert = now
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        } else if Int(id) == cloudWindowNumber {
            guard !cloudWindow.isKey else { return }
            lastFocusReassert = now
            cloudWindow.reassertKey()
        } else {
            // ⚠️ 2026-11-19 兜底：启动阶段也可能出现 cloudTargetWindowID 未设（未走 open(cloud:)，
            //   例如重启 App 后直接开驾驶）。此时按采集窗口 id 反查其所属 App 并激活，
            //   否则前台永远停在控制台 → 焦点判定失败 → 10s 超时死循环。
            guard let pid = Self.ownerPID(ofWindow: id),
                  let app = NSRunningApplication(processIdentifier: pid), !app.isActive else { return }
            lastFocusReassert = now
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    /// 按 CGWindowID 反查所属进程 pid（窗口不存在返回 nil）。
    static func ownerPID(ofWindow id: CGWindowID) -> pid_t? {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
        guard let raw = info?.first?[kCGWindowOwnerPID as String] as? Int else { return nil }
        return pid_t(exactly: raw)
    }

    /// 激活云游戏所在的浏览器 App（全局注入按键会送到最前台 App）。
    private func activateCloudBrowser() {
        guard let pid = cloudTargetAppPID,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    /// 兜底启动脚本（外置盘启动器 app 缺失时用它；脚本内部会 `env -u` 掉
    /// `__CFBundleIdentifier` 再拉起去沙盒副本）。
    static func externalLaunchScriptURL() -> URL? {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".yihuan/launch.sh")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "选择《异环》"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Bundle(url: url)?.bundleIdentifier == Self.bundleID else {
            status = "请选择《异环》游戏 App"
            return
        }
        UserDefaults.standard.set(url.path, forKey: pathKey)
        discover()
    }

    func open(cloud: Bool, state: DriveState) async {
        guard !busy else { return }
        busy = true
        needsWindow = true
        choices = []
        // 启动来源：必须在 bind() 之前记录（bind 消费它做定位决策）。
        pendingLaunchSource = cloud ? .cloud : .local
        defer {
            busy = false
            state.finishLauncherWindowConnection(error: needsWindow ? status : nil)
        }
        do {
            if cloud {
                // 用系统真实浏览器打开（Chrome 优先、Safari 兜底），再抓浏览器窗口。
                // 不再用内置 WKWebView：实测它抓不到游戏画面、也不接受合成按键。
                guard let browser = BrowserLauncher.preferredBrowser() else {
                    status = "未找到 Google Chrome 或 Safari，请先安装浏览器"
                    return
                }
                status = "正在用 \(browser.name) 打开云游戏"
                let existing = GameWindowFocus.existingWindowIDs()
                let app = try await BrowserLauncher.openCloudGame(BrowserLauncher.cloudGameURL, browser: browser)
                status = "等待云游戏窗口（\(browser.name)）"
                let launchedAt = ProcessInfo.processInfo.systemUptime
                let deadline = launchedAt + 90
                var retryWindow: CapturableWindow?
                var captureFailures = 0
                var captureError: String?
                while ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled {
                    // CG supplies window IDs in z-order. The capture process resolves the selected ID to an SCWindow.
                    let windows = GameWindowFocus.browserWindows(browser)
                    let front = windows.first?.id
                    let launchSettled = ProcessInfo.processInfo.systemUptime - launchedAt >= 1
                    let retained = (launchSettled ? launchedCloudWindow : nil).flatMap { previous in
                        windows.first { $0.id == front && BrowserLauncher.isSameWindow(previous, $0) }
                    }
                    let retry = retryWindow.flatMap { previous in
                        windows.first { BrowserLauncher.isSameWindow(previous, $0) }
                    }
                    if let win = BrowserLauncher.launchedWindow(in: windows, browserBundleID: browser.bundleID,
                                                               browserPID: app.processIdentifier,
                                                               frontWindowID: front, existing: existing,
                                                               allowReuse: launchSettled) ?? retry ?? retained,
                       launchSettled || !win.title.isEmpty {
                        if win.id != retryWindow?.id { captureFailures = 0 }
                        await bind(win, state: state)
                        if state.captureMode == .window(id: win.id), state.captureModeError == nil {
                            launchedCloudWindow = win
                            // 窗口已连上 → 主动铺满主屏（Chrome --app 的 --window-size
                            // 交给已运行实例时经常被忽略，窗口会以默认小尺寸出现）。
                            GameWindowFocus.maximizeToScreen(win)
                            return
                        }
                        captureError = state.captureModeError
                        retryWindow = win
                        captureFailures += 1
                        if captureFailures >= 4, let pid = win.ownerPID, GameWindowFocus.exists(win.id, pid: pid) {
                            return
                        }
                        status = "正在重新连接云游戏画面"
                        try await Task.sleep(for: .milliseconds(250 * min(captureFailures, 4)))
                        continue
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
                status = captureError ?? "未能连接云游戏窗口，请将云游戏页面切到前台后重试"
                return
            }
            // 本地：外置盘架构下「机器唯一正确实例」由 LaunchAgent com.dupi.yihuan.autolaunch
            // 守护保活，PID 随时会被换。所以：
            //   ① 绝不能用 LaunchServices 再拉一个（会注入 __CFBundleIdentifier 卡死、并被守护杀掉）；
            //   ② 绝不能按“自己启动时的 PID”找窗口（守护一换 PID 就永远匹配不上）。
            // 正确做法：优先复用已在运行的实例；没在跑时才走外置盘启动器（wrapper → launch.sh），
            // 然后用 bundleID 匹配任意实例的窗口。
            discover()
            // 用「窗口是否已经存在」判断游戏是否在跑（比查进程可靠：launch.sh 直接 exec 二进制，
            // 不一定注册为 LaunchServices 应用）。守护保活的实例随时在，直接复用即可。
            let preexisting = Self.matchesAnyInstance(await CaptureEngine.listWindows())
            if preexisting.isEmpty {
                if let wrapper = Self.externalWrapperURL() {
                    status = "正在启动《异环》（外置盘）"
                    if !NSWorkspace.shared.open(wrapper) {
                        status = "外置盘启动器无法打开，请确认外置盘已挂载"
                        return
                    }
                } else if let script = Self.externalLaunchScriptURL() {
                    status = "正在启动《异环》（launch.sh）"
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/bash")
                    p.arguments = [script.path]
                    do { try p.run() } catch {
                        status = "启动器执行失败：\(error.localizedDescription)"
                        return
                    }
                } else {
                    status = "未找到外置盘启动器（~/Applications/异环（外置盘）.app 或 ~/.yihuan/launch.sh）"
                    return
                }
            } else {
                status = "检测到已在运行的《异环》，正在定位窗口"
            }
            status = "等待游戏窗口"
            for _ in 0..<90 {
                let windows = await CaptureEngine.listWindows()
                let matches = Self.matchesAnyInstance(windows)
                if matches.count == 1 {
                    await bind(matches[0], state: state)
                    return
                }
                if matches.count > 1 {
                    choices = matches
                    status = "请选择游戏窗口"
                    return
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            status = "未找到游戏窗口，请确认游戏已打开且已授予「屏幕录制」权限"
        } catch {
            status = error.localizedDescription
        }
    }

    /// 按 bundleID 匹配**任意**实例的窗口（忽略 PID）—— 守护换 PID 后仍能定位。
    /// 多窗口时优先「判定为游戏窗口」的，其次按面积；避免误绑登录/启动器窗口。
    /// `matches(pid:)` 保留给自检与普通启动路径，语义不变。
    static func matchesAnyInstance(_ windows: [CapturableWindow]) -> [CapturableWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let matched = windows.filter {
            $0.ownerPID != ownPID &&
            $0.bundleIdentifier == bundleID &&
            $0.width >= 640 && $0.height >= 360 &&
            !$0.title.localizedCaseInsensitiveContains("launcher") &&
            !$0.title.contains("启动器")
        }
        let games = matched.filter { $0.isGame }
        let pool = games.isEmpty ? matched : games
        return pool.sorted { ($0.width * $0.height) > ($1.width * $1.height) }
    }

    static func matches(_ windows: [CapturableWindow], pid: pid_t) -> [CapturableWindow] {
        windows.filter {
            guard $0.ownerPID == pid, $0.width >= 640, $0.height >= 360 else { return false }
            return $0.bundleIdentifier == bundleID &&
                !$0.title.localizedCaseInsensitiveContains("launcher") && !$0.title.contains("启动器")
        }
    }

    /// 待提交的启动来源：open(cloud:) 的各分支记录，bind() 消费后清空。
    /// 手动选窗/用户自启时为 nil → .unknown（靠浏览器判定）。
    private(set) var pendingLaunchSource: PositioningLaunchSource?

    func bind(_ window: CapturableWindow, state: DriveState) async {
        guard !state.shellModeActive, state.shellStartCountdown.remaining == 0 else { return }
        let resumeDriving = state.driveRequested && state.driveStatus == "等待游戏窗口恢复"
        if resumeDriving { state.stopDriving() }
        choices = []
        // 速度表 ROI 归属：浏览器（云端云游戏）→ 云端坐标；本地异环 → 本地坐标。
        // 全屏采集没有窗口可判，全靠这个标志（CaptureEngine.fullScreen 分支读它）。
        let isBrowser = CaptureEngine.isCloudBrowserOwner(bundleID: window.bundleIdentifier,
                                                                  name: window.applicationName)
        state.cloudROIHint = isBrowser
        // 定位方式决策（云端→视觉 / 本地→网络 / 未知→按浏览器）：绑定窗口时提交一次。
        state.commitPositioningSource(launchSource: pendingLaunchSource ?? .unknown,
                                      captureIsBrowser: isBrowser)
        pendingLaunchSource = nil
        await state.selectCaptureMode(.window(id: window.id), startPreview: true)
        if state.captureModeError == nil { remember(window) }
        status = state.captureModeError ?? "采集目标 · \(window.displayLabel)"
        if resumeDriving, state.captureModeError == nil { state.startDriving() }
    }

    func offerChoices(_ windows: [CapturableWindow], status: String) {
        if choices != windows { choices = windows }
        if self.status != status { self.status = status }
    }

    func remember(_ window: CapturableWindow) {
        boundWindow = window
        if CaptureEngine.isCloudBrowserOwner(bundleID: window.bundleIdentifier, name: window.applicationName) {
            cloudTargetWindowID = window.id
            cloudTargetAppPID = window.ownerPID
        }
    }

    private(set) var boundWindow: CapturableWindow?

    func isLaunchedCloudWindow(_ window: CapturableWindow) -> Bool {
        launchedCloudWindow.map { BrowserLauncher.isSameWindow($0, window) } ?? false
    }

    /// 上次启动的云游戏窗口（供驾驶启动时自动重发现使用；只读）。
    var preferredCloudWindow: CapturableWindow? { launchedCloudWindow }

    func rememberCloudReplacement(_ window: CapturableWindow) {
        launchedCloudWindow = window
    }

    static func replacements(for target: CapturableWindow, in windows: [CapturableWindow]) -> [CapturableWindow] {
        if target.bundleIdentifier == bundleID { return matchesAnyInstance(windows) }
        let matches = BrowserLauncher.gameWindows(in: windows, browserBundleID: target.bundleIdentifier, browserPID: nil)
        let sameInstance = matches.filter { $0.ownerPID == target.ownerPID }
        return sameInstance.isEmpty ? matches : sameInstance
    }

    static func isDrivingTarget(_ window: CapturableWindow) -> Bool {
        guard window.ownerPID != nil else { return false }
        if !matchesAnyInstance([window]).isEmpty { return true }
        return CaptureEngine.isCloudBrowserOwner(bundleID: window.bundleIdentifier, name: window.applicationName)
            && !BrowserLauncher.gameWindows(in: [window], browserBundleID: window.bundleIdentifier, browserPID: nil).isEmpty
    }

}

struct GameSourceRail: View {
    let state: DriveState
    @State private var expanded = false
    private var launcher: GameLauncher { state.gameLauncher }

    var body: some View {
        HStack(spacing: 4) {
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        Button {
                            Task { await launcher.open(cloud: false, state: state) }
                        } label: {
                            VStack {
                                if let icon = launcher.icon {
                                    Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                                } else { Image(systemName: "gamecontroller").frame(width: 32, height: 32) }
                                Text("本地")
                            }
                        }
                        .help("启动本地《异环》并选择游戏窗口")
                        .contextMenu { Button("选择游戏 App…") { launcher.chooseApp() } }
                        Button {
                            Task { await launcher.open(cloud: true, state: state) }
                        } label: {
                            VStack {
                                Image(systemName: "cloud.fill").font(.title2).frame(width: 32, height: 32)
                                Text("云端")
                            }
                        }
                        .help("打开异环云游戏")
                    }
                    ForEach(launcher.choices) { window in
                        Button(window.displayLabel + " · #\(window.id)") {
                            Task { await launcher.bind(window, state: state) }
                        }
                    }
                    if !launcher.status.isEmpty {
                        Text(launcher.status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 145, alignment: .leading)
                .padding(10)
                .disabled(launcher.busy || state.shellModeActive || state.shellStartCountdown.remaining > 0)
            }
            Button {
                expanded.toggle()
                if expanded { launcher.discover() }
            } label: {
                Image(systemName: expanded ? "chevron.left" : "chevron.right")
                    .frame(width: 20, height: 54).contentShape(Rectangle())
            }
            .help(expanded ? "收起游戏入口" : "展开游戏入口")
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
