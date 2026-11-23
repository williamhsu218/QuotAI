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

    @Test("CLI snapshots publish immediately and merge the asynchronous subscription plan")
    func cliSnapshotMergesAsyncSubscriptionPlan() async throws {
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        let cliSnapshot = AntigravityQuotaSnapshot(
            fetchedAt: AntigravityQuotaSnapshot.preview.fetchedAt,
            groups: AntigravityQuotaSnapshot.preview.groups,
            subscriptionPlan: nil,
            thirdPartyAvailability: .available,
            source: .cli
        )
        let planGate = Gate()
        let planCalls = CallLog<Int>()
        let shouldFail = LockedValue(false)
        let nextPlan = LockedValue<SubscriptionPlan?>(SubscriptionPlan(identifier: "Google AI Pro"))
        let store = AntigravityUsageStore(
            defaults: defaults.defaults,
            fetchSnapshot: { cliSnapshot },
            fetchCLISubscriptionPlan: {
                let count = await planCalls.values.count + 1
                await planCalls.append(count)
                await planGate.wait()
                if shouldFail.value { throw ProbeFailure() }
                return nextPlan.value
            },
            cliPlanRefreshInterval: 3_600,
            installationDetector: { true }
        )
        store.start()
        defer { store.stop() }

        try await waitUntil("CLI quota is ready before plan finishes") { store.phase == .ready }
        #expect(store.snapshot?.source == .cli)
        #expect(store.snapshot?.subscriptionPlan == nil)

        await planGate.open()
        try await waitUntil("CLI plan merges onto snapshot") {
            store.snapshot?.subscriptionPlan?.displayName == "Pro"
        }
        #expect(await planCalls.values.count == 1)

        // Periodic refresh within the refresh interval keeps the cached plan without re-probing.
        await store.refresh()
        #expect(store.snapshot?.subscriptionPlan?.displayName == "Pro")
        #expect(await planCalls.values.count == 1)

        // Manual refresh forces a re-probe; transient failures retain the last known plan.
        shouldFail.value = true
        await store.userRefresh()
        try await waitUntil("manual refresh triggers plan re-probe") { await planCalls.values.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.snapshot?.subscriptionPlan?.displayName == "Pro")

        // Confirmed plan change updates the badge.
        shouldFail.value = false
        nextPlan.value = SubscriptionPlan(identifier: "Google AI Ultra")
        await store.userRefresh()
        try await waitUntil("updated CLI plan replaces previous badge") {
            store.snapshot?.subscriptionPlan?.displayName == "Ultra"
        }
    }

    @Test("Stopping cancels an in-flight CLI subscription plan probe")
    func stopRejectsLateCLISubscriptionPlan() async throws {
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        let cliSnapshot = AntigravityQuotaSnapshot(
            fetchedAt: AntigravityQuotaSnapshot.preview.fetchedAt,
            groups: AntigravityQuotaSnapshot.preview.groups,
            subscriptionPlan: nil,
            thirdPartyAvailability: .available,
            source: .cli
        )
        let planGate = Gate()
        let planReturned = CallLog<Bool>()
        let store = AntigravityUsageStore(
            defaults: defaults.defaults,
            fetchSnapshot: { cliSnapshot },
            fetchCLISubscriptionPlan: {
                await planGate.wait()
                await planReturned.append(true)
                return SubscriptionPlan(identifier: "Google AI Pro")
            },
            installationDetector: { true }
        )
        store.start()
        try await waitUntil("CLI snapshot is ready") { store.phase == .ready }

        store.stop()
        await planGate.open()
        try await waitUntil("late plan probe finishes") { await planReturned.values.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.snapshot == nil && store.phase == .idle)
    }
}
