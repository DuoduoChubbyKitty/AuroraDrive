// SPDX-FileCopyrightText: 2026 AuroraDrive
// SPDX-License-Identifier: GPL-3.0-or-later

// ============================================================================
//  PositioningResolver.swift — 定位方式决策（视觉 / 网络）
// ----------------------------------------------------------------------------
//  用户规则（2026-11-20，逐条翻译自需求原话）：
//    ① 内置启动器走云端（open(cloud: true)）      → 视觉定位（小地图匹配）
//       云游戏只有视频流，拿不到 UDP 坐标包，网络定位天然无源。
//    ② 内置启动器走本地（open(cloud: false)）      → 网络定位（CoordinateCapture）
//       本地 UE5 进程发 tcp:30031 坐标包，精度远高于视觉。
//    ③ 用户自己启动、来源未知                      → 看抓屏目标是不是浏览器窗口
//       （CaptureEngine.isCloudBrowserOwner）：是浏览器 → 云端 → 视觉；
//       不是（本地游戏进程）→ 网络。
//
//  输入全部来自现有状态，不新增任何采集链路：
//    · GameLauncher.cloudTargetWindowID != nil  → 走过云端启动（.cloud）
//    · launchSettled 的本地会话               → 走过本地启动（.local）
//    · 其余                                    → .unknown + 浏览器判定
// ============================================================================

import Foundation

/// 定位方式。
enum PositioningMode: String {
    /// 视觉定位：小地图模板匹配（MapLocBridge，云端唯一可用路径）。
    case visual
    /// 网络定位：CoordinateCapture 抓 tcp:30031 坐标包（本地精度更高）。
    case network
}

/// 启动来源（由内置启动器路径决定，与用户实际怎么开的游戏一一对应）。
enum PositioningLaunchSource: String {
    /// 内置启动器 → 云端（open(cloud: true)）
    case cloud
    /// 内置启动器 → 本地（open(cloud: false)）
    case local
    /// 用户自己启动 / 尚未经内置启动器
    case unknown
}

/// 纯函数决策器：无状态、无 IO，三条规则 + 真值表见文件头。
enum PositioningResolver {

    /// - Parameters:
    ///   - launchSource: 启动来源（cloud / local / unknown）。
    ///   - captureIsBrowser: 抓屏目标是否浏览器窗口
    ///     （CaptureEngine.isCloudBrowserOwner 的结果；unknown 时才被读到）。
    /// - Returns: 该用的定位方式。
    static func resolve(launchSource: PositioningLaunchSource,
                        captureIsBrowser: Bool) -> PositioningMode {
        switch launchSource {
        case .cloud:
            // 规则①：云端只有视频流，没有坐标包可抓。
            return .visual
        case .local:
            // 规则②：本地进程发 tcp:30031，网络定位精度更高。
            return .network
        case .unknown:
            // 规则③：靠浏览器窗口识别推断云端/本地。
            return captureIsBrowser ? .visual : .network
        }
    }
}
