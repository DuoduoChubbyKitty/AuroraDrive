// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  MouseController.swift — 鼠标注入引擎（CGEvent）
//  通过 CGEvent 向系统注入鼠标事件：移动 / 单击 / 双击 / 拖拽
//  用途：AI Agent 自动登录（识别登录按钮坐标后点击）、UI 自动化技能
//
//  与 ControlEngine 完全同源的注入策略：
//  - CGEventSource 用 .hidSystemState（HID 系统状态层）
//    实测异环 NTE 的输入层只读取该层的合成事件（见 ControlEngine 注释），
//    .combinedSessionState / .privateState 会被游戏忽略，禁止使用。
//  - 投递 tap 用 .cghidEventTap（硬件事件层，最底层，游戏必响应）。
//
//  坐标系说明（重要，曾在这里差点犯错）：
//  - CGEvent 鼠标事件的坐标是「全局显示坐标」，单位为点（point），
//    原点在主显示器左上角，y 轴向下增长 —— 与截图像素坐标（同样左上原点）
//    只差一个 backingScaleFactor（Retina 下 2x），方向完全一致。
//  - NSScreen.frame 的坐标才是「左下原点」的 AppKit 坐标，两者不要混用。
//    换算：CGEvent 点坐标 = 截图像素坐标 / backingScaleFactor（主屏时）。
// ============================================================================

import AppKit
import CoreGraphics

/// 鼠标注入引擎（@Observable 供 UI 观察最近一次操作）
@Observable
final class MouseController: @unchecked Sendable {

    /// 最近一次注入的坐标（诊断展示用）
    private(set) var lastClickPoint: CGPoint = .zero

    /// 累计成功注入的鼠标事件数（诊断用）
    @ObservationIgnored private(set) var postedEventCount: Int = 0

    /// CGEventSource（与 ControlEngine 同层：HID 系统状态）
    private let eventSource: CGEventSource? = CGEventSource(stateID: .hidSystemState)

    /// 主显示器缩放系数（截图像素 → 屏幕点的换算用）
    /// CaptureEngine 配置截屏分辨率 = screen.frame.width × backingScaleFactor（真像素），
    /// 所以「截图像素坐标 ÷ 本值 = CGEvent 点坐标」。
    static var displayScale: CGFloat {
        let screen = NSScreen.screens.first ?? NSScreen.main
        return screen?.backingScaleFactor ?? 1.0
    }

    /// 主显示器逻辑尺寸（点）
    static var displaySize: CGSize {
        let screen = NSScreen.screens.first ?? NSScreen.main
        return screen?.frame.size ?? CGSize(width: 1920, height: 1080)
    }

    // MARK: - 移动

    /// 移动鼠标到全局点坐标（不点击）
    @discardableResult
    func move(to point: CGPoint) -> Bool {
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            print("[MouseController] CGEvent 创建失败 move \(point)")
            return false
        }
        event.post(tap: .cghidEventTap)
        postedEventCount &+= 1
        return true
    }

    // MARK: - 单击

    /// 在全局点坐标处左键单击（移动 → down → up）
    /// - Parameters:
    ///   - point: 全局点坐标（左上原点）
    ///   - settleDelay: 移动后到按下的缓冲（秒），给游戏 UI 光标跟随留时间
    @discardableResult
    func click(at point: CGPoint, settleDelay: TimeInterval = 0.08) -> Bool {
        // 先移动过去 —— 部分游戏 UI 只在光标悬停时才响应点击
        guard move(to: point) else { return false }
        usleep(useconds_t(settleDelay * 1_000_000))

        guard let down = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            print("[MouseController] CGEvent 创建失败 click \(point)")
            return false
        }
        down.post(tap: .cghidEventTap)
        // 按住 ~40ms，模拟真人点击节奏（0ms 的 down→up 会被部分 UI 判定为抖动）
        usleep(40_000)
        up.post(tap: .cghidEventTap)

        lastClickPoint = point
        postedEventCount &+= 2
        print("[MouseController] click at (\(Int(point.x)), \(Int(point.y)))")
        return true
    }

    /// 在全局点坐标处左键双击
    @discardableResult
    func doubleClick(at point: CGPoint) -> Bool {
        guard let down = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let down2 = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let up2 = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return false }
        // 双击第二击的 clickCount 标记为 2（系统判定双击的依据）
        down2.setIntegerValueField(.mouseEventClickState, value: 2)
        up2.setIntegerValueField(.mouseEventClickState, value: 2)

        down.post(tap: .cghidEventTap)
        usleep(30_000)
        up.post(tap: .cghidEventTap)
        usleep(60_000)
        down2.post(tap: .cghidEventTap)
        usleep(30_000)
        up2.post(tap: .cghidEventTap)

        lastClickPoint = point
        postedEventCount &+= 4
        return true
    }

    // MARK: - 滚轮

    /// 滚动鼠标滚轮（游戏内场景：自动滚动拾取/翻页等）
    /// - Parameter lines: 滚动行数（正值向下，负值向上；-120 约等于一格）
    /// - Parameter at: 滚轮事件发送位置（默认当前位置）
    @discardableResult
    func scrollWheel(lines: Int32, at point: CGPoint? = nil) -> Bool {
        let pos = point ?? NSEvent.mouseLocation.flippedScreenPoint()
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .line,
            wheelCount: 1,
            wheel1: lines,
            wheel2: 0,
            wheel3: 0
        ) else {
            print("[MouseController] CGEvent 创建失败 scrollWheel")
            return false
        }
        event.location = pos
        event.post(tap: .cghidEventTap)
        postedEventCount &+= 1
        return true
    }

    // MARK: - 坐标换算

    /// 截图像素坐标 → 全局点坐标
    /// - Parameters:
    ///   - pixel: 截图中的像素坐标（左上原点，与 Vision 归一化框换算后的方向一致）
    ///   - scale: 截图像素/屏幕点 的缩放比（Retina 主屏 = 2.0）
    static func screenPoint(fromPixel pixel: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: pixel.x / scale, y: pixel.y / scale)
    }
}

/// NSEvent.mouseLocation 是左下原点（AppKit），转 CGEvent 的左上原点
private extension NSPoint {
    func flippedScreenPoint() -> CGPoint {
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: x, y: screenH - y)
    }
}
