import Foundation
import Observation

@MainActor
@Observable
final class AntigravityTokenStore {
    private(set) var snapshot: AntigravityTokenSnapshot?
    private(set) var isLoading = false
    private(set) var failed = false
    var panelIsVisible = false
    @ObservationIgnored private let previewMode: Bool
    @ObservationIgnored private let readSnapshot: @Sendable () async throws -> AntigravityTokenSnapshot

    init(previewMode: Bool = false,
         previewSnapshot: AntigravityTokenSnapshot? = nil,
         readSnapshot: (@Sendable () async throws -> AntigravityTokenSnapshot)? = nil) {
        self.previewMode = previewMode
        let reader = AntigravityTokenReader()
        self.readSnapshot = readSnapshot ?? { try await reader.read() }
        if previewMode { snapshot = previewSnapshot ?? .preview }
    }

    // Deliberately not called by either provider's periodic quota refresh loop.
    func refresh() async {
        guard !previewMode, !isLoading, !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let value = try await readSnapshot()
            try Task.checkCancellation()
            snapshot = value
            failed = false
        } catch is CancellationError {
            // Closing the panel cancels its bounded read, never creates a retry.
        } catch {
            failed = true // Keep previously observed values, visibly stale.
        }
    }
}
