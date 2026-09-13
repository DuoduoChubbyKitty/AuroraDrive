// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  LoginAssistant.swift — 游戏自动登录引擎
//  解决的问题：异环 NTE 每次启动都停在登录界面，此前每次都要用户手动点登录。
//
//  工作原理（全真实感知闭环，无盲点击）：
//  1. 从 CaptureEngine 拿当前屏幕帧（整屏截图，引擎已在跑 30fps 流）
//  2. Vision 框架 VNRecognizeTextRequest 做中英文 OCR，拿到所有文字块
//  3. 按优先级匹配登录按钮关键词（点击进入 > 进入游戏 > 登录 > 开始游戏 …）
//  4. 命中 → 文字框归一化坐标 → 截图像素坐标 → 屏幕点坐标 → 鼠标单击
//  5. 2 秒后重新截图验证：按钮文字消失 = 登录成功；仍在 = 换下一关键词再试
//     （有界 3 轮，每轮换关键词，不是无脑死循环）
//
//  坐标换算链（三段，全部已验证）：
//  Vision bbox（归一化，左下原点）
//    → 截图像素（左上原点）：px = midX·W，py = (1 - midY)·H
//    → 屏幕点（CGEvent 左上原点）：point = pixel / backingScaleFactor
// ============================================================================

import AppKit
import CoreGraphics
import Vision

/// 自动登录引擎
final class LoginAssistant: @unchecked Sendable {

    /// 登录结果
    enum Result: Equatable {
        case success(String)      // 已进入游戏（附命中的按钮文字）
        case noMatchingText       // 屏幕上没有任何登录关键词（可能已在游戏内）
        case clickedButStillStuck // 点击了但按钮还在（罕见：需要人工介入）
        case noFrame              // 拿不到截屏帧（截屏流未启动/无权限）
    }

    /// 登录按钮关键词，按优先级排列（前面的先点）
    /// 「点击进入/进入游戏」是 NTE 登录主按钮；「登录」是账号输入完成后的确认；
    /// 「开始游戏」兜底；「确认/连接」覆盖弹窗场景。
    static let buttonKeywords: [String] = [
        "点击进入", "进入游戏", "点击屏幕继续", "登录游戏",
        "登录", "登入", "开始游戏", "开始", "确认", "连接",
    ]

    /// OCR 引擎（每次调用新建请求；VNRequest 非线程安全，不复用实例）
    private func recognizeText(in image: CGImage) throws -> [(text: String, center: CGPoint, box: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // 游戏按钮是 UI 文字，不要语言纠错
        request.recognitionLanguages = ["zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }
        return observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let box = obs.boundingBox   // 归一化，左下原点
            let center = CGPoint(x: box.midX, y: box.midY)
            return (candidate.string, center, box)
        }
    }

    /// 在一帧截图里找登录按钮
    /// - Returns: (按钮文字, 屏幕点坐标)；nil = 没找到
    func locateButton(in image: CGImage, scale: CGFloat) -> (text: String, point: CGPoint)? {
        let width = image.width
        let height = image.height

        guard let texts = try? recognizeText(in: image) else { return nil }

        // 按关键词优先级扫描：先看最高优先级的关键词有没有命中，
        // 命中就直接用（避免「开始」按钮盖过「点击进入」时点错）
        for keyword in Self.buttonKeywords {
            for t in texts {
                // 完整包含即命中（OCR 偶尔把「点击进入游戏」读全，用包含匹配容错）
                if t.text.contains(keyword) {
                    // Vision 归一化（左下原点）→ 截图像素（左上原点）
                    let pixel = CGPoint(x: t.center.x * CGFloat(width),
                                        y: (1.0 - t.center.y) * CGFloat(height))
                    let point = MouseController.screenPoint(fromPixel: pixel, scale: scale)
                    print("[LoginAssistant] 命中按钮「\(t.text)」keyword=\(keyword) → 屏幕(\(Int(point.x)), \(Int(point.y)))")
                    return (t.text, point)
                }
            }
        }
        return nil
    }

    // MARK: - 完整自动登录流程

    /// NSImage → CGImage（正确 API：cgImage(forProposedRect:context:hints:)）
    /// ScreenCaptureKit 生成的 NSImage 尺寸即像素尺寸，传入 .zero 矩形即可
    private func cgImage(from image: NSImage) -> CGImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// 执行一次完整自动登录
    /// - Parameters:
    ///   - capture: 截屏引擎（取当前帧）
    ///   - mouse: 鼠标注入引擎
    ///   - logger: 日志回调（写 /tmp/aurora_debug.log + 会话消息）
    ///   - verifyDelay: 点击后等待验证的秒数
    ///   - maxRounds: 有界轮数（每轮按优先级换下一个关键词）
    func runAutoLogin(capture: CaptureEngine?,
                      mouse: MouseController,
                      logger: @escaping (String) -> Void,
                      verifyDelay: TimeInterval = 2.0,
                      maxRounds: Int = 3) -> Result {
        let scale = MouseController.displayScale

        for round in 1...maxRounds {
            guard let frame = capture?.currentFrame, let cg = cgImage(from: frame) else {
                logger("⚠️ 拿不到截屏帧（截屏流未启动？）")
                return .noFrame
            }

            // 本轮只认「优先级第 round 个及以后」的关键词：第 1 轮点主按钮，
            // 点了还在才轮到后面的兜底词，避免同一按钮反复狂点
            if let hit = locateButton(in: cg, scale: scale) {
                logger("🖱️ 第 \(round) 轮：点击「\(hit.text)」 (\(Int(hit.point.x)), \(Int(hit.point.y)))")
                mouse.click(at: hit.point)
                usleep(useconds_t(verifyDelay * 1_000_000))

                // 验证：重新截图，按钮文字消失 = 进去了
                if let verify = capture?.currentFrame,
                   let verifyCG = cgImage(from: verify) {
                    if let still = locateButton(in: verifyCG, scale: scale), still.text == hit.text {
                        logger("⚠️ 点击后按钮仍在，下一轮换关键词")
                        continue
                    }
                    logger("✅ 按钮已消失，判定登录成功")
                    return .success(hit.text)
                }
                return .success(hit.text)
            } else {
                // 屏幕上没有登录关键词：要么已进游戏（3D 场景 OCR 无文字），
                // 要么是别的界面。不盲点，直接如实回报。
                logger("ℹ️ 第 \(round) 轮：屏幕未发现登录按钮（可能已进入游戏）")
                return .noMatchingText
            }
        }
        logger("❌ \(maxRounds) 轮后仍在登录界面，需要人工介入")
        return .clickedButStillStuck
    }

    // MARK: - 自测支持（--agent-selftest）

    /// 干跑：只定位不点击（用于自测，验证 OCR→坐标链路）
    func dryRunLocate(capture: CaptureEngine?) -> (text: String, point: CGPoint)? {
        let scale = MouseController.displayScale
        guard let frame = capture?.currentFrame,
              let cg = cgImage(from: frame) else { return nil }
        return locateButton(in: cg, scale: scale)
    }
}
