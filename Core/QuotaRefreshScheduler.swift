import Foundation

/// Replaces only the timer when preferences change. A refresh already in
/// progress retains its own timeout and completes through the store's gate.
@MainActor
final class QuotaRefreshScheduler {
    private var loop: Task<Void, Never>?
    private let interval: @MainActor @Sendable () -> TimeInterval
    private let tick: @MainActor @Sendable () -> Void
    var isRunning: Bool { loop != nil }

    init(interval: @escaping @MainActor @Sendable () -> TimeInterval,
         tick: @escaping @MainActor @Sendable () -> Void) {
        self.interval = interval
        self.tick = tick
    }

    func start() {
        guard loop == nil else { return }
        let interval = interval, tick = tick
        loop = Task {
            while !Task.isCancelled {
                let configured = interval()
                do { try await Task.sleep(for: .seconds(configured > 0 && configured.isFinite ? configured : 300)) }
                catch { return }
                guard !Task.isCancelled else { return }
                tick()
            }
        }
    }

    func reschedule() {
        guard isRunning else { return }
        stop()
        start()
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    deinit { loop?.cancel() }
}
