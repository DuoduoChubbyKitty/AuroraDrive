// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// UI 与用户会话 Agent 共用的 XPC 服务名。
public enum AuroraDriveServiceIdentity {
    public static let machServiceName = "com.aurora.drive.agent"
    public static let launchAgentLabel = "com.aurora.drive.agent"
    public static let protocolVersion = 1
}

/// 用户会话 Agent 的最小 XPC 接口。
///
/// 当前阶段只提供健康检查和生命周期信号，不把任意 shell 命令暴露给 XPC 客户端。
/// 后续迁移捕获/推理/控制时，应继续沿用窄接口，不直接暴露引擎对象。
@objc public protocol AuroraDriveUserAgentProtocol {
    func ping(withReply reply: @escaping (Int, String) -> Void)
    func startDriving(withReply reply: @escaping (Bool, String) -> Void)
    func stopDriving(withReply reply: @escaping (Bool, String) -> Void)
}
