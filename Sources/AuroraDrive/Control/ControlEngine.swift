// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ═══════════════════════════════════════════════════════════════════════════
// 【出处标注 · 品牌澄清】2026-10-04
//   本文件的**游戏键位表**（`GameKey` 枚举，:408 附近）取自上游开源项目
//   **MaaNTE** 实际使用的键集合。下文注释里的「MaaNTE」是**上游项目名**，
//   用于交代键位清单的来源 —— **它不是本产品的品牌**。
//   本产品品牌：`AuroraDrive`（见 `App/AuroraBrand.swift`）。
//   保留出处的理由：键位表是"游戏输入层实测结论"的集合（哪些键游戏认、
//   哪些层能投递），抹掉出处就无法复核某个键为什么在表里。
//   故：出处保留；品牌层（用户可见字符串 / 标识符）不得出现上游名。
// ═══════════════════════════════════════════════════════════════════════════
// ============================================================================
//  ControlEngine.swift — 按键注入引擎（CGEvent）
//  通过 CGEvent 向系统注入键盘事件，控制游戏（WASD + 空格 + Shift）
//  支持按下/释放/持续按住，支持按键映射配置
//  需要"辅助功能"权限（Accessibility）
// ============================================================================

import AppKit
import CoreGraphics
import Observation

/// 按键注入引擎
/// - 通过 CGEvent 向系统全局键盘队列注入按键事件
/// - 支持 press（按下后立即释放）、hold（持续按住）、release（释放）
/// - 按键映射可通过 keyMap 自定义
/// - 启动时检查辅助功能权限，无权限时引导用户到系统设置
/// - @Observable 让 SwiftUI 自动观察按键状态变化（键盘可视化条用）
@Observable
final class ControlEngine: @unchecked Sendable {

    /// 按键动作枚举（语义化，与具体键位解耦）
    enum Action {
        case throttle    // 油门（前进）
        case brake       // 刹车（后退）
        case steerLeft   // 左转
        case steerRight  // 右转
        case handbrake   // 手刹（空格）
        case boost       // 极速（Shift）
    }

    /// 按键映射：语义动作 → macOS 键码
    /// macOS 键码参考（HID Usage Table → macOS virtualKey）：
    /// W=13, A=0, S=1, D=2, 空格=49, LeftShift=56, RightShift=60
    struct KeyMap {
        var throttle:    CGKeyCode = 13   // W
        var brake:       CGKeyCode = 1    // S
        var steerLeft:   CGKeyCode = 0    // A
        var steerRight:  CGKeyCode = 2    // D
        var handbrake:   CGKeyCode = 49   // 空格
        var boost:       CGKeyCode = 56   // Left Shift

        /// 根据语义动作获取键码
        func keyCode(for action: Action) -> CGKeyCode {
            switch action {
            case .throttle:    return throttle
            case .brake:       return brake
            case .steerLeft:   return steerLeft
            case .steerRight:  return steerRight
            case .handbrake:   return handbrake
            case .boost:       return boost
            }
        }
    }

    /// 当前按键映射（可运行时修改）
    var keyMap = KeyMap()

    /// 是否拥有辅助功能权限
    private(set) var hasAccessibilityPermission = false

    /// 当前按住的键集合（@Observable，键盘可视化条观察此属性）
    /// 每次按下/释放都更新，SwiftUI 自动刷新键帽颜色
    private(set) var heldKeys: Set<CGKeyCode> = []

    /// 累计成功注入的键盘事件总数（诊断用：判断事件流是否持续产生）
    /// 标记 @ObservationIgnored：此值每帧递增，不应触发 SwiftUI 重绘。
    @ObservationIgnored private(set) var postedEventCount: Int = 0

    // MARK: - 按住键重发节流（可选，默认关闭）

    /// 按住键重发的目标频率（Hz）。**0 = 关闭节流 = 每个控制周期都重发**
    /// （即改动前的行为，30Hz）。
    ///
    /// ══════════════════════════════════════════════════════════════════════════
    /// ⚠️ 为什么做成「默认关闭的开关」而不是直接改默认值
    /// ══════════════════════════════════════════════════════════════════════════
    ///
    /// 【背景】`refreshHeldKeys` 每控制周期（30Hz）对每个按住键重发一次 keyDown。
    ///   实测（`/tmp/aurora_tickprobe.log`，节流前）事件速率约 **185 次/秒**；
    ///   当前稳态（1 转向键 + 1 油门/刹车键）理论值约 **60 次/秒**。
    ///   特征：keyDown 流、**无对应 keyUp**、autorepeat=false、间隔**严格 33.3ms**。
    ///   时间维度上是完美周期信号，与真人键盘（首次延迟 ~500ms → 系统生成带
    ///   autorepeat 的重复 → 频繁变键）差异明显。
    ///
    /// 【为什么不当默认值】两条硬约束打架：
    ///   · 用户硬要求「确保**没有降任何频率**」—— 节流本身就是在降注入频率；
    ///   · 本项目纪律「所有改动都带 `AURORA_*` 开关，否则做不了 ABBA 对比」
    ///     （见 `releaseAllIfNeeded` 的注释）。
    ///   而且**降低注入频率是否会让游戏丢键，只能在真机上验证** —— 代码里
    ///   `refreshHeldKeys` 的注释明确记录过历史事故：重发不足会表现为
    ///   「UI 显示 W 已按住，游戏纹丝不动」。**本机当前没有游戏**，无法验证。
    ///
    /// 【因此】默认 0（行为与改动前**逐帧一致**）。要启用：
    ///   `AURORA_KEY_REFRESH_HZ=20 ./AuroraDriveUI`
    ///   启用后**必须真机验证车还能动**，尤其 E2E 直道恒定油门档。
    ///
    /// 【抖动】节流启用时，阈值取 `周期 × random(0.75…1.25)` —— 打破严格周期，
    ///   但不额外减少事件数（平均频率仍 ≈ 目标频率）。**抖动本身不降频**，
    ///   它只是把事件时刻从「33.3ms 网格」上挪开。
    ///
    /// 【未改动】`autorepeat` 仍恒为 false（`:305-308` 注释：带 autorepeat 标记的
    ///   keyDown 会被目标游戏忽略，改了会直接导致车不动）。
    // A17 迁移（2026-10-04，lead 授权只改这一行）：
    //   原来在这里现读 `ProcessInfo.processInfo.environment["AURORA_KEY_REFRESH_HZ"]`
    //   并做 `>0 && <=60` 校验 —— 该校验**已逐字搬进** `AuroraFlags.keyRefreshHz`
    //   （非法输入一律回退 0），故这里只做单位换算：**Hz → 间隔**。
    //   ⚠️ 单位陷阱：`AuroraFlags.keyRefreshHz` 是频率（Hz），本常量要的是间隔（秒）。
    private static let keyRefreshInterval: Double =
        AuroraFlags.keyRefreshHz > 0 ? 1.0 / AuroraFlags.keyRefreshHz : 0

    /// 上次重发按住键的时刻（`CACurrentMediaTime`）。0 = 本会话还没重发过。
    /// 仅在主线程访问（`refreshHeldKeys` 由 tick 调用），无需加锁。
    @ObservationIgnored private var lastKeyRefreshAt: CFAbsoluteTime = 0

    /// CGEventSource（HID 系统状态层，注入的键对游戏「等同于真实物理按键」）
    private let eventSource: CGEventSource? = {
        // 必须用 .hidSystemState（对应 C API 的 kCGEventSourceStateHIDSystemState）：
        // 实测目标游戏（异环 NTE）的输入层只读取 HID 系统状态层的键盘事件。
        //
        // - .combinedSessionState（曾用）：实测对该游戏无效。该层的合成事件会被
        //   系统 UI 正常接收（键盘可视化条会亮、系统提示音会响），但游戏输入层
        //   直接忽略，表现为「UI 显示已输出 W，但游戏纹丝不动」。
        // - .privateState：更私有的状态层，游戏更加读不到，禁止使用。
        // - .hidSystemState：事件进入 HID 系统状态层，与真实物理键盘同层，
        //   配合下方 .cghidEventTap 投递，即为已验证可突破该游戏反作弊拦截的方案。
        return CGEventSource(stateID: .hidSystemState)
    }()

    // MARK: - 权限

    /// 检查辅助功能权限（macOS 10.9+）
    /// 无权限时注入事件会被系统静默丢弃
    ///
    /// ⚠️ 本方法**只查询、不弹窗**（`AXIsProcessTrustedWithOptions(nil)`）。
    ///    需要「请求授权」请用 `requestAccessibilityPermission()`。
    func checkPermission() -> Bool {
        // AXIsProcessTrustedWithOptions 会触发系统授权弹窗（首次）
        // kAXTrustedCheckOptionPrompt: true 表示弹窗提示
        // 
        // P0 修复 (2026-09-07): 字符串字面量 "kAXTrustedCheckOptionPrompt" 不是有效的
        // CFString 常量，导致 options 字典无效 → AXIsProcessTrustedWithOptions 收到
        // nil 等价参数 → 访问空指针崩溃 (EXC_BAD_ACCESS at 0x8)。
        // 
        // 正确做法：直接传 nil（不弹窗）或用 kAXTrustedCheckOptionPrompt as String
        // 作为 key。这里改为传 nil：首次调用会自动弹系统授权提示，后续调用仅返回
        // 当前权限状态，与原本期望行为一致。
        //
        // ⚠️ 2026-09-30 更正：上面这句「首次调用会自动弹系统授权提示」是**错的**。
        //    传 `nil` 时 AXIsProcessTrustedWithOptions **只查询、绝不弹窗** ——
        //    这正是本轮实测到的现象：程序从未出现在
        //    「系统设置 → 隐私与安全性 → 辅助功能」列表里，
        //    因为**从来没有发出过授权请求**，用户想授权都找不到条目。
        //    故拆分为两个方法：本方法保持"纯查询"（`press`/`hold` 的高频重试路径
        //    绝不能弹窗，否则每帧弹一次），新增 `requestAccessibilityPermission()`
        //    专用于启动/注入引擎的时机请求一次。
        let trusted = AXIsProcessTrustedWithOptions(nil)
        hasAccessibilityPermission = trusted
        return trusted
    }

    /// 显式**请求**辅助功能权限（会触发系统授权弹窗，并把本程序登记进
    /// 「系统设置 → 隐私与安全性 → 辅助功能」列表）。
    ///
    /// 与 `checkPermission()` 的分工（都很重要，不可合并）：
    ///   · `checkPermission()` —— 纯查询，**不弹窗**。用于每帧都可能走的路径
    ///     （`press`/`hold` 的 `guard hasAccessibilityPermission else` 重试分支），
    ///     在那里弹窗会导致每帧一次弹窗风暴。
    ///   · `requestAccessibilityPermission()` —— **弹窗 + 登记**。只在
    ///     「初始化注入引擎」「启动时权限检查失败」这类一次性时机调用。
    ///
    /// 背景（2026-09-30 实测）：修复前全项目只有 `AXIsProcessTrustedWithOptions(nil)`
    /// 一种调用，即**只查询不请求** → 程序永远不进辅助功能列表 → 用户手动也无法
    /// 授权 → `ControlEngine` 所有注入被系统静默丢弃（表现为
    /// `[Agent] ❌ 辅助功能权限未授权，无法注入鼠标`，自动登录/技能全部失效）。
    ///
    /// - Returns: 当前是否已获授权（首次调用通常为 false，需用户在系统设置里勾选）。
    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        // `kAXTrustedCheckOptionPrompt` 必须作为 CFString key 传入（用 `as String` 桥接）。
        // 2026-09-07 的崩溃正是字符串字面量直接用导致字典无效，这里沿用已验证的桥接写法。
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        hasAccessibilityPermission = trusted
        if !trusted {
            // 弹窗后系统设置会被打开到对应面板，用户可在列表里看到本程序并勾选。
            // 这里再主动打开一次设置面板，减少一步操作（幂等，重复打开无副作用）。
            openAccessibilitySettings()
        }
        return trusted
    }

    /// 打开系统设置的辅助功能面板（引导用户授权）
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 屏幕录制权限（2026-09-30 新增）
    // ══════════════════════════════════════════════════════════════════════════
    //
    // 【为什么必须补这一段】此前全项目只有 **查询**、没有 **申请**：
    //     `CGPreflightScreenCaptureAccess()`  —— EngineMain.swift:632
    //                                          —— AuroraDriveApp.swift:158
    //     两处都是纯查询（该 API 按设计不弹窗、不注册）。
    //     而 `CGRequestScreenCaptureAccess()`  **全项目零调用**，
    //     打开「屏幕录制」设置面板的代码也**从未存在**。
    //
    // 【后果（实测）】系统设置的「屏幕录制」列表里**根本不会出现本 App**——
    //   用户想手动勾选都找不到地方。这解释了为什么历次运行
    //   `--tcc-selftest` 恒为 `screen=false`，且从未有授权弹窗出现。
    //   `CaptureEngine.start()` 依赖 `SCShareableContent.current` 抛错时
    //   「顺带弹窗」（见 CaptureEngine.swift:161 的注释），但那只是网络/显示器
    //   枚举失败时的**被动**行为，**不负责把 App 注册进 TCC 列表**。
    //
    // 【与辅助功能的对称性】辅助功能那一路上一轮已修好
    //   （`checkPermission()` → `requestAccessibilityPermission()`，
    //   屏幕上出现的 `universalAccessAuthWarn` 弹窗即其证据）。
    //   屏幕录制是**同一类遗漏的对称位置**——当时只补了一半。
    //
    // 【为什么放在 ControlEngine 这个类型里】它与辅助功能权限是同一职责的两项
    //   （都是「注入/观测所需的一次性系统授权」），放一起便于对照维护；
    //   本类型已 import AppKit（`NSWorkspace` 可用）。若另起新类型，
    //   反而会在项目里多出一个职责重叠的权限入口。

    /// 申请屏幕录制权限（会弹系统授权框，并把本 App 注册进 TCC 列表）
    ///
    /// - Returns: 申请后是否已获授权。
    ///   ⚠️ 首次调用几乎必然返回 `false` —— 用户需在弹出的系统设置里手动勾选，
    ///   **且勾选后通常要重启本 App** 才生效（TCC 对屏幕录制的判定是进程级的）。
    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        // `CGRequestScreenCaptureAccess()` 的作用：首次调用时弹出系统授权提示，
        // 并把本 App 登记到「隐私与安全性 → 屏幕录制」列表中（未登记的 App
        // 在该列表里不可见）。它自身也返回当前是否已授权。
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            // 与辅助功能那一路保持一致：弹窗之后系统设置会被打开到对应面板，
            // 再主动打开一次（幂等，重复打开无副作用），减少用户一步操作。
            openScreenRecordingSettings()
        }
        return granted
    }

    /// 打开系统设置的「屏幕录制」面板（引导用户授权）
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 启动期申请屏幕录制权限（无需实例，供 AppDelegate 直接调用）
    ///
    /// 【为什么需要这个「启动期」版本】`captureEngine.start()` 只在
    ///   `startDriving()` 里被调用，而 `startDriving()` 开头有一道
    ///   **辅助功能**权限守卫（`guard … requestAccessibilityPermission()
    ///   || controlDisabled else { return }`）。于是默认路径形成死锁：
    ///
    ///       没有辅助功能权限 → startDriving 提前 return
    ///                        → captureEngine.start() 永不执行
    ///                        → onStatusChange 永不收到 .permissionDenied
    ///                        → 屏幕录制权限的申请代码永不触发
    ///                        → 屏幕录制永远拿不到
    ///
    ///   而**屏幕录制与辅助功能本应是两个互相独立的权限**，不该有先后依赖：
    ///   「看画面」不需要「能按键」。此方法把屏幕录制的申请从 startDriving
    ///   里解耦出来，挂到 `applicationDidFinishLaunching`。
    ///
    /// 【为什么不直接复用 `requestScreenRecordingPermission()`】
    ///   那个版本在被拒时会主动打开系统设置面板，适合用户主动点「开始驾驶」
    ///   时的引导；而**每次启动都弹设置面板会很打扰**。这里只走系统授权框
    ///   （该弹窗自带「打开系统设置」按钮），把选择权留给用户。
    ///
    /// 【幂等且安静】已授权时 `CGPreflightScreenCaptureAccess()` 直接返回 true，
    ///   不做任何弹窗 —— 即正常用户完全感觉不到这段代码存在。
    @discardableResult
    static func requestScreenRecordingPermissionOnStartup() -> Bool {
        guard !CGPreflightScreenCaptureAccess() else { return true }
        return CGRequestScreenCaptureAccess()
    }

    // MARK: - 按键注入

    /// 按下并立即释放一个键（短按）
    /// - Parameter action: 语义动作
    /// - Parameter duration: 按住时长（秒），默认 0.05s（50ms）
    func press(_ action: Action, duration: TimeInterval = 0.05) {
        guard hasAccessibilityPermission else {
            _ = checkPermission()
            return
        }
        let keyCode = keyMap.keyCode(for: action)
        postKeyEvent(keyCode: keyCode, keyDown: true)
        // 短暂等待后释放（模拟真实按键时长）
        usleep(useconds_t(duration * 1_000_000))
        postKeyEvent(keyCode: keyCode, keyDown: false)
    }

    /// 持续按住一个键（不释放，直到调用 release 或 releaseAll）
    /// - Parameter action: 语义动作
    func hold(_ action: Action) {
        guard hasAccessibilityPermission else {
            _ = checkPermission()
            return
        }
        let keyCode = keyMap.keyCode(for: action)
        // 避免重复按下（已按住则跳过）
        if heldKeys.contains(keyCode) { return }
        postKeyEvent(keyCode: keyCode, keyDown: true)
        heldKeys.insert(keyCode)
    }

    /// 释放一个键
    /// - Parameter action: 语义动作
    func release(_ action: Action) {
        let keyCode = keyMap.keyCode(for: action)
        guard heldKeys.contains(keyCode) else { return }
        postKeyEvent(keyCode: keyCode, keyDown: false)
        heldKeys.remove(keyCode)
    }

    /// 刷新所有按住键的按下状态（每个控制周期调用一次）
    ///
    /// 为什么必须有这一步：
    /// 真实物理键盘按住不放时，键盘硬件会持续向系统上报按键状态，系统据此
    /// 持续产生带 autorepeat 标记的 keyDown 事件流。游戏的输入状态机依赖
    /// 这个事件流判断"键还按着"。
    ///
    /// 而 CGEvent 注入是「一次性事件」：hold() 只在按下瞬间发一个 keyDown，
    /// 之后若控制量保持稳定（例如 E2E 模型在直道恒定输出 throttle=0.98），
    /// 就再也不会有任何键盘事件产生 —— 系统键盘状态虽然是"按住"，但游戏
    /// 从未收到过属于它的事件，表现为「UI 显示 W 已按住，游戏纹丝不动」。
    ///
    /// 因此持续按住的键必须按周期重发 keyDown。调用频率跟随控制主循环（30Hz），
    /// 与 macOS 默认按键重复率同量级。
    ///
    /// 关键：重发的 keyDown 必须是「新按下」语义（autorepeat = false）。
    /// 带 autorepeat 标记的事件会被该游戏的输入层忽略（它只认新按下），
    /// 导致稳定输出档位（如 M9）下只有 auto-repeat 事件流、游戏完全不动。
    /// 已验证方案（V1）同样是每次都发新按下，此处与之对齐。
    ///
    /// ── 可选节流 + 抖动 ──
    /// `Self.keyRefreshInterval == 0`（默认）时本函数**与改动前逐帧一致**：
    /// 每个控制周期对每个按住键重发一次。
    /// 设为非 0（`AURORA_KEY_REFRESH_HZ`）后启用节流，阈值带 ±25% 抖动 ——
    /// 打破「严格 33.3ms 周期」这一机器特征。理由与风险见
    /// `keyRefreshInterval` 的文档注释（**默认关闭**，需真机验证）。
    func refreshHeldKeys() {
        guard hasAccessibilityPermission, !heldKeys.isEmpty else { return }

        if Self.keyRefreshInterval > 0 {
            let now = CACurrentMediaTime()
            // 抖动：把事件时刻从固定网格上挪开，但不额外减少事件数
            let threshold = Self.keyRefreshInterval * Double.random(in: 0.75...1.25)
            if lastKeyRefreshAt > 0, now - lastKeyRefreshAt < threshold { return }
            lastKeyRefreshAt = now
        }

        for keyCode in heldKeys {
            postKeyEvent(keyCode: keyCode, keyDown: true)
        }
    }

    /// 释放所有按住的键（停止自动驾驶时调用，避免按键卡住）
    /// 无条件对所有映射键发释放事件：即使本会话没记录按过（例如上次进程
    /// 异常退出残留的系统级卡键），也主动清掉，保证系统键盘状态干净。
    func releaseAll() {
        let allMappedKeys: [CGKeyCode] = [
            keyMap.throttle, keyMap.brake,
            keyMap.steerLeft, keyMap.steerRight,
            keyMap.handbrake, keyMap.boost,
        ]
        for keyCode in allMappedKeys {
            postKeyEvent(keyCode: keyCode, keyDown: false)
        }
        heldKeys.removeAll()
        // ★ 阶段4（2026-10-01）：记录"刚做过全量清扫"，
        //   供 tick 侧的节流版本 `releaseAllIfNeeded()` 判断可否跳过。
        lastFullReleaseAt = CACurrentMediaTime()
    }

    // MARK: - 阶段4（2026-10-01）：按键注入折叠

    /// 上次执行全量清扫（6 键 keyUp）的时刻。0 = 本会话从未清扫过。
    private var lastFullReleaseAt: CFAbsoluteTime = 0

    /// ★ 阶段4（2026-10-01 性能折叠）：节流版全量释放。
    ///
    /// 【为什么加】生产 tick 分段剖析（`--tick-profile` / `AURORA_PERF=1` 日志）
    ///   实测 `tick.inject` p50=**0.15ms**，占整帧 `tick.total`(0.21ms) 的 **71%**
    ///   —— 是当前 tick 内**最大的单项主线程成本**，比其它所有阶段加起来还多。
    ///
    /// 【根因】`expertMode || controlDisabled` 分支每帧调 `releaseAll()`，
    ///   而无条件对 6 个键各发一次 `CGEvent.post(tap: .cghidEventTap)`
    ///   （实测 `ev=` 计数每 30s 涨约 2000，与 6×30Hz 吻合）。
    ///   但该分支的语义只是"别注入 AI 键" —— 键**本来就没被按下**时，
    ///   这 6 次 keyUp 是纯粹的白工（release 本来幂等，且无键可释放）。
    ///
    /// 【改动语义】`releaseAll()` 本身**一字未改**（仍是"无条件清 6 键 + 清表"），
    ///   因为它还承担「清上次进程异常退出残留的系统级卡键」这一安全职责，
    ///   那个场景下**必须**无条件发。本方法只是在 tick 的每帧路径上加一层
    ///   **节流**：同一秒内已经清扫过、且当前无按住键 → 跳过重复清扫。
    ///
    /// 【安全边界（为什么节流是安全的）】
    ///   · `heldKeys` 为空  → 本进程没按住任何键，没有东西需要释放；
    ///   · 距上次全量清扫 < 1s → 残留（若有）已被那一次清掉，
    ///     1 秒内不可能凭空出现新的系统级残留（残留只来自**上一次进程退出**）；
    ///   · 任何**真实释放需求**都不走这里 —— `applyCommand` 走 `release(_:)`，
    ///     停止驾驶走 `releaseAll()`，两者都不受影响。
    ///   · 最坏情况：某次残留未被及时清理 —— 但下一帧仍在同一秒内跳过，
    ///     而 1 秒后必然执行一次全量清扫，收敛行为与改前**一致**（改前是
    ///     每秒 30 次清扫，改后每秒 1 次，覆盖同一场景）。
    ///
    /// 【等价性证明方法】见 `--perf-selftest` 与文档 §6.44：
    ///   ABBA 对比 `tick.inject` p50（改前 0.15ms → 改后应为 ~0.01ms），
    ///   同时验证 `heldKeys` 状态与 `applyCommand` 路径行为逐帧一致。
    func releaseAllIfNeeded() {
        // 有按住键 → 必须走完整清扫（这是真实的释放需求，不可省）
        if !heldKeys.isEmpty {
            releaseAll()
            return
        }
        // 无按住键：同一秒内已清扫过就跳过，否则清扫一次
        let now = CACurrentMediaTime()
        if lastFullReleaseAt > 0, now - lastFullReleaseAt < 1.0 { return }
        releaseAll()
    }

    // MARK: - 底层 CGEvent 注入

    /// 发送键盘事件（keyDown 或 keyUp）
    /// - Parameters:
    ///   - keyCode: macOS 键码
    ///   - keyDown: true=按下, false=释放
    ///   - autorepeat: 是否标记为「按住重复」事件（对应真实键盘的 auto-repeat）。
    ///                 保留该参数以备其他输入层使用，但针对目标游戏必须保持
    ///                 默认 false —— 该游戏输入层只认「新按下」，会忽略
    ///                 auto-repeat 事件（详见 refreshHeldKeys 说明）。
    private func postKeyEvent(keyCode: CGKeyCode, keyDown: Bool, autorepeat: Bool = false) {
        // CGEvent 创建：nil eventSource 时使用默认源
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: keyCode,
            keyDown: keyDown
        ) else {
            print("[ControlEngine] CGEvent 创建失败 keyCode=\(keyCode) keyDown=\(keyDown)")
            return
        }

        // 仅在显式要求时标记为按键重复事件。
        // 注意：目标游戏（异环 NTE）会忽略带 auto-repeat 标记的 keyDown，
        // 因此所有实际调用路径均使用默认 false，即每次都发「新按下」。
        if autorepeat {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }

        // postToPid 注入到特定进程（更精确，但需要 PID）
        // 这里用 CGEvent.post 全局注入，对所有前台应用生效
        // tap: .cghidEventTap 注入到硬件事件层（最底层，游戏必响应）
        event.post(tap: .cghidEventTap)
        postedEventCount &+= 1
    }

    // MARK: - AI Agent 游戏键位支持

    /// 游戏常用键枚举（MaaNTE 实际使用的所有键）
    ///
    /// ⚠️ 注释里的数字是**macOS 虚拟键码**（`kVK_ANSI_*`，来自 HID Usage Table 的
    ///    USB Keyboard 页，但**不是** ASCII 码，也不是 Windows VK_* 码）。
    ///    权威来源：`Carbon/HIToolbox/Events.h` 的 `kVK_*` 常量。
    ///    验证方式见 `gameKeyToKeyCode` 上方的缺陷记录。
    enum GameKey: String, CaseIterable {
        // 移动
        case w = "W"   // 13
        case a = "A"   // 0
        case s = "S"   // 1
        case d = "D"   // 2
        // 交互
        case f = "F"   // 3
        case e = "E"   // 14
        case space = "Space"  // 49
        // UI
        case esc = "ESC"  // 53
        case q = "Q"     // 12
        case r = "R"     // 15
        case m = "M"     // 46
        case b = "B"     // 11
        case t = "T"     // 17
        // 异环 HUD 功能热键（G2：rewards 入口页切换用；实测 F3=卡布罗集市 F4=活动页）
        case f1 = "F1"   // 122
        case f2 = "F2"   // 120
        case f4 = "F4"   // 118
        // 修饰键
        case shift = "Shift"   // 56 (kVK_Shift = Left Shift)
        case ctrl = "Ctrl"     // 59 (kVK_Control = Left Control)
        // 数字选择
        case one = "1"   // 18
        case two = "2"   // 19
        case three = "3" // 20
        case four = "4"  // 21
        case five = "5"  // 23
        case six = "6"   // 22
        case seven = "7" // 26
        // 俄罗斯方块 / 节奏游戏
        case j = "J"     // 38
        case k = "K"     // 40
        case l = "L"     // 37
        // 钢琴低音
        case z = "Z"     // 6
        case x = "X"     // 7
        case c = "C"     // 8
        case v = "V"     // 9
        case n = "N"     // 45
        // 钢琴中音
        case g = "G"     // 5
        case h = "H"     // 4
        case i = "I"     // 34
        // 钢琴高音
        case y = "Y"     // 16
        case u = "U"     // 32
    }

    /// GameKey → CGKeyCode 映射表。
    ///
    /// ══════════════════════════════════════════════════════════════════════════
    /// ⚠️ 2026-10-06 缺陷修复记录（W8 独立验证发现，Lead 授权修复）
    /// ══════════════════════════════════════════════════════════════════════════
    ///
    /// 【原缺陷】本表最初误用 **ASCII / Windows `VK_*` 码**当作 macOS `CGKeyCode`
    ///   （W=87、A=65、S=83、D=68、Space=32、ESC=27、Shift=0xA0、Ctrl=0xA2 …），
    ///   38 项里 **35 项错误**。macOS 把 87 解释成**小键盘 5**、65 是**小键盘 `.`**、
    ///   83 是**小键盘 1**、32 是 **`u`**、27 是 **`-`**、0xA0/0xA2 **无字符** ——
    ///   即自动按键类技能/工具**发出去的全是错键**（车仍能动，因为驾驶路径走的是
    ///   下方 `KeyMap`，那张表本来就对）。
    ///
    /// 【三重独立取证】（原始输出：`verify/evidence-llm/finding-F1-gamekey-keycodes.txt`）
    ///   ① Carbon `kVK_*` 权威常量对照 → 35/38 不符
    ///   ② 向 `.cghidEventTap` 注入 `virtualKey=87`，自建 CGEventTap 抓回后读
    ///      `keyboardGetUnicodeString` → 得到 `"5"`（注入 13 则正确得到 `"w"`）
    ///   ③ 系统键盘布局翻译 `TIS`/`UCKeyTranslate` → 87 翻译为 `5`
    ///   验证入口：`./AuroraDriveUI --control-selftest`（会断言每个键的 Unicode 翻译）
    ///
    /// 【为什么以前没被发现】`KeyMap`（:48-58，驾驶路径 W/S/A/D/空格/Shift）用的是
    ///   **正确**键码，所以自动驾驶一直正常；`GameKey` 只服务 AI 技能与工具注入路径，
    ///   而那条路径此前没有「抓回事件读翻译」的验证手段 —— 直到 W8 的
    ///   `--control-selftest` 四证据链把这一环补上。
    private static let gameKeyToKeyCode: [GameKey: CGKeyCode] = [
        .w: 13, .a: 0, .s: 1, .d: 2,
        .f: 3, .e: 14, .space: 49,
        .esc: 53, .q: 12, .r: 15, .m: 46, .b: 11, .t: 17,
        .f1: 122, .f2: 120, .f4: 118,
        .shift: 56, .ctrl: 59,
        .one: 18, .two: 19, .three: 20, .four: 21,
        .five: 23, .six: 22, .seven: 26,
        .j: 38, .k: 40, .l: 37,
        .z: 6, .x: 7, .c: 8, .v: 9, .n: 45,
        .g: 5, .h: 4, .i: 34,
        .y: 16, .u: 32,
    ]

    /// 根据游戏键名获取 CGKeyCode
    func keyCode(for key: GameKey) -> CGKeyCode? {
        return Self.gameKeyToKeyCode[key]
    }

    /// 按下并释放一个游戏键（短按）
    func pressGameKey(_ key: GameKey, duration: TimeInterval = 0.05) {
        guard let keyCode = keyCode(for: key) else { return }
        postKeyEvent(keyCode: keyCode, keyDown: true)
        usleep(useconds_t(duration * 1_000_000))
        postKeyEvent(keyCode: keyCode, keyDown: false)
    }

    /// 持续按住一个游戏键
    func holdGameKey(_ key: GameKey) {
        guard let keyCode = keyCode(for: key) else { return }
        if heldKeys.contains(keyCode) { return }
        postKeyEvent(keyCode: keyCode, keyDown: true)
        heldKeys.insert(keyCode)
    }

    /// 释放一个游戏键
    func releaseGameKey(_ key: GameKey) {
        guard let keyCode = keyCode(for: key) else { return }
        guard heldKeys.contains(keyCode) else { return }
        postKeyEvent(keyCode: keyCode, keyDown: false)
        heldKeys.remove(keyCode)
    }

    /// 批量释放所有游戏键（不影响驾驶语义键的追踪，但清理所有 held 状态）
    func releaseAllGameKeys() {
        let gameKeyCodes = Self.gameKeyToKeyCode.map { $0.value }
        let toRelease = heldKeys.filter { gameKeyCodes.contains($0) }
        for keyCode in toRelease {
            postKeyEvent(keyCode: keyCode, keyDown: false)
        }
        heldKeys.subtract(toRelease)
    }

    /// 文本输入（聊天刷屏类技能用）：Unicode 字符串注入到当前焦点输入框
    /// 注意：文字进入「当前拥有键盘焦点的输入框」，调用方需先自行把焦点切到目标
    /// （如按 F/回车打开游戏聊天框），并受游戏窗口护栏约束
    func typeText(_ text: String) {
        let utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else {
            print("[ControlEngine] typeText CGEvent 创建失败")
            return
        }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        postedEventCount &+= 2
    }

    // MARK: - 状态查询

    /// 某个键是否正在按住
    func isHeld(_ action: Action) -> Bool {
        let keyCode = keyMap.keyCode(for: action)
        return heldKeys.contains(keyCode)
    }

    /// 某个游戏键是否正在按住
    func isHeld(_ key: GameKey) -> Bool {
        guard let keyCode = keyCode(for: key) else { return false }
        return heldKeys.contains(keyCode)
    }

    /// 当前按住的键数量
    var heldCount: Int {
        return heldKeys.count
    }
}
