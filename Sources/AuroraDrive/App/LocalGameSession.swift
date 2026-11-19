import AppKit

@MainActor
final class LocalGameSession {
    private var owned: NSRunningApplication?
    private var launching = false
    private var pendingQuit: (() -> Void)?

    func open(_ url: URL, bundleID: String) async throws -> NSRunningApplication {
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated }) {
            existing.activate()
            return existing
        }

        launching = true
        defer {
            launching = false
            if let pendingQuit {
                self.pendingQuit = nil
                pendingQuit()
            }
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.allowsRunningApplicationSubstitution = false
        let game = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        owned = game
        return game
    }

    func deferQuitDuringLaunch(_ reply: @escaping () -> Void) -> Bool {
        guard launching else { return false }
        pendingQuit = reply
        return true
    }

    func quitOwnedGame() {
        if let owned, !owned.isTerminated { _ = owned.terminate() }
        owned = nil
    }
}
