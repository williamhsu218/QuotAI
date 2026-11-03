import Foundation
import Testing
@testable import QuotAICore

private struct ProbeFailure: Error {}

/// Serves queued results to the store's injected fetch.
private actor Responses {
    private var queue: [Result<AntigravityQuotaSnapshot, any Error>]
    init(_ queue: [Result<AntigravityQuotaSnapshot, any Error>]) { self.queue = queue }
    func next() throws -> AntigravityQuotaSnapshot { try queue.removeFirst().get() }
}

@MainActor
@Suite("Antigravity usage store")
struct AntigravityUsageStoreTests {
    @Test("Starting refreshes once and publishes the snapshot")
    func startPublishesSnapshot() async throws {
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        let store = AntigravityUsageStore(
            defaults: defaults.defaults,
            fetchSnapshot: { .preview },
            installationDetector: { true }
        )
        store.start()
        defer { store.stop() }

        try await waitUntil("the first refresh finishes") { store.phase == .ready }
        #expect(store.isEnabled && store.isInstalled)
        #expect(store.snapshot == .preview)
    }

    @Test("A failed refresh clears the snapshot so unavailable never looks like zero")
    func failureClearsSnapshot() async throws {
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        let responses = Responses([.success(.preview), .failure(AntigravityQuotaClientError.notRunning)])
        let store = AntigravityUsageStore(
            defaults: defaults.defaults,
            fetchSnapshot: { try await responses.next() },
            installationDetector: { true }
        )
        store.start()
        defer { store.stop() }
        try await waitUntil("the first refresh finishes") { store.phase == .ready }

        await store.refresh()

        let message = try #require(AntigravityQuotaClientError.notRunning.errorDescription)
        #expect(store.snapshot == nil)
        #expect(store.phase == .failed(message))
    }

    @Test("Stopping during a refresh rejects its late result")
    func stopRejectsLateResult() async throws {
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        let gate = Gate()
        let finished = CallLog<Bool>()
        let store = AntigravityUsageStore(
            defaults: defaults.defaults,
            fetchSnapshot: {
                await gate.wait()
                await finished.append(true)
                return .preview
            },
            installationDetector: { true }
        )
        store.start()
        try await waitUntil("the refresh is in flight") { store.isLoading }

        store.stop()
        #expect(!store.isEnabled && store.phase == .idle && store.snapshot == nil)

        await gate.open()
        try await waitUntil("the late fetch returns") { await finished.values.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.snapshot == nil)
        #expect(store.phase == .idle)
    }

    @Test("Uninstalling Antigravity clears its snapshot")
    func uninstallClearsSnapshot() async throws {
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        let installed = LockedValue(true)
        let store = AntigravityUsageStore(
            defaults: defaults.defaults,
            fetchSnapshot: { .preview },
            installationDetector: { installed.value }
        )
        store.start()
        defer { store.stop() }
        try await waitUntil("the first refresh finishes") { store.phase == .ready }

        installed.value = false
        store.reloadInstallation()

        #expect(!store.isInstalled)
        #expect(store.snapshot == nil && store.phase == .idle)
        await store.userRefresh()
        #expect(store.snapshot == nil)
    }

    @Test("An unexpected fetch error is reported without a snapshot")
    func unexpectedError() async throws {
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        let store = AntigravityUsageStore(
            defaults: defaults.defaults,
            fetchSnapshot: { throw ProbeFailure() },
            installationDetector: { true }
        )
        store.start()
        defer { store.stop() }
        try await waitUntil("the refresh fails") {
            if case .failed = store.phase { return true } else { return false }
        }
        #expect(store.snapshot == nil)
    }
}
