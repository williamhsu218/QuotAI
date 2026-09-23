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
         failed: Bool = false,
         readSnapshot: (@Sendable () async throws -> AntigravityTokenSnapshot)? = nil) {
        self.previewMode = previewMode
        let reader = AntigravityTokenReader()
        self.readSnapshot = readSnapshot ?? { try await reader.read() }
        if previewMode {
            snapshot = previewSnapshot ?? .preview
            self.failed = failed
        }
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

    /// Explicit user action to read multiple historical slices in sequence.
    /// Each slice is protected by the Reader's single-slice budget.
    func continueHistory() async {
        guard !previewMode, !isLoading, !Task.isCancelled, panelIsVisible else { return }
        if let current = snapshot, current.pendingFiles == 0 { return }

        isLoading = true
        defer { isLoading = false }

        let maxSlices = 24
        let deadline = ProcessInfo.processInfo.systemUptime + 2.0
        var prevPending = snapshot?.pendingFiles ?? Int.max

        for _ in 0..<maxSlices {
            guard panelIsVisible, !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else {
                break
            }
            do {
                let nextSnapshot = try await readSnapshot()
                try Task.checkCancellation()
                guard panelIsVisible else { break }
                snapshot = nextSnapshot
                failed = false

                if nextSnapshot.pendingFiles == 0 {
                    break
                }

                let pendingDecreased = nextSnapshot.pendingFiles < prevPending
                let readWork = nextSnapshot.rowsRead > 0 || nextSnapshot.bytesRead > 0
                guard pendingDecreased || readWork else {
                    break
                }
                prevPending = nextSnapshot.pendingFiles

                await Task.yield()
            } catch is CancellationError {
                break
            } catch {
                failed = true
                break
            }
        }
    }
}
