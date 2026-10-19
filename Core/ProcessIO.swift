import Foundation

/// Blocking pipe reads and child reaping belong on a Dispatch worker, never
/// Swift's cooperative executor. Each provider owns its queue to avoid one
/// provider's timeout delaying another provider.
enum ProcessIO {
    static func run<T: Sendable>(
        on queue: DispatchQueue,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }
}
