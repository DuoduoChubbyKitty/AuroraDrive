import Foundation
import Observation

@Observable
@MainActor
final class ShellStartCountdown {
    private(set) var remaining = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(seconds: Int = 30, onExpiry: @escaping @MainActor () -> Void) {
        cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        remaining = seconds
        task = Task { [weak self] in
            for next in (0..<seconds).reversed() {
                do {
                    try await Task.sleep(until: deadline.advanced(by: .seconds(-next)), clock: .continuous)
                } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.remaining = next
            }
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            onExpiry()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        remaining = 0
    }
}
