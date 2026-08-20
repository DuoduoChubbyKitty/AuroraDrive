// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Minimal stub for MetalGoose's `MouseConstraintManager` (cursor-drawing helper).
// The full implementation lives in MetalGoose's OverlayWindowManager.swift and is
// intentionally NOT vendored. GooseEngine only requires this single accessor on the
// display path, so a trivial stub is sufficient. This file is AuroraDrive's own
// addition and is NOT part of the upstream GPL v3.0 source.

import Foundation
import CoreGraphics

final class MouseConstraintManager: @unchecked Sendable {
    static let shared = MouseConstraintManager()
    // 上游返回光标位置归一化坐标 (CGPoint?)；此处给视口中心，仅用于显示路径光标点
    func currentCursorFraction() -> CGPoint? { CGPoint(x: 0.5, y: 0.5) }
}
