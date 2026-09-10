// SPDX-FileCopyrightText: 2026 DuoduoChubbyKitty
// SPDX-License-Identifier: GPL-3.0-or-later

import AuroraDriveShared
import Foundation

private final class UserAgentService: NSObject, AuroraDriveUserAgentProtocol {
    private let lock = NSLock()
    private var drivingRequested = false

    func ping(withReply reply: @escaping (Int, String) -> Void) {
        reply(AuroraDriveServiceIdentity.protocolVersion, "ready")
    }

    func startDriving(withReply reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        drivingRequested = true
        lock.unlock()
        reply(true, "accepted")
    }

    func stopDriving(withReply reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        drivingRequested = false
        lock.unlock()
        reply(true, "accepted")
    }
}

private final class UserAgentDelegate: NSObject, NSXPCListenerDelegate {
    private let service = UserAgentService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: AuroraDriveUserAgentProtocol.self
        )
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

private let delegate = UserAgentDelegate()
private let listener = NSXPCListener(
    machServiceName: AuroraDriveServiceIdentity.machServiceName
)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
