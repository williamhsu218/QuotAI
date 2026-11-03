import Foundation
import Testing

@testable import QuotAICore

private func usageSnapshot(at now: Date, usedFive: Double = 15) -> ClaudeCodeQuotaSnapshot {
    ClaudeCodeQuotaSnapshot(
        fiveHour: ClaudeCodeQuotaReport(
            kind: .fiveHour, usedPercentage: usedFive,
            resetsAt: now.addingTimeInterval(3_600), firstObservedAt: now),
        sevenDay: ClaudeCodeQuotaReport(
            kind: .sevenDay, usedPercentage: 9,
            resetsAt: now.addingTimeInterval(3 * 86_400), firstObservedAt: now),
        sessionFingerprint: "usage-query",
        lastCallbackAt: now,
        source: .usageQuery
    )
}

/// Builds an enabled store whose CLI, queries and caches are all injected.
@MainActor
private func makeStore(
    defaults: IsolatedDefaults,
    directory: TemporaryDirectory,
    executable: URL? = URL(fileURLWithPath: "/usr/bin/true"),
    subscription: @escaping @Sendable () async throws -> ClaudeCodeSubscriptionPlan? = { .pro },
    query: @escaping @Sendable () async throws -> ClaudeCodeQuotaSnapshot
) -> ClaudeCodeUsageStore {
    defaults.defaults.set(true, forKey: DefaultsKey.claudeCodeUsageQuery)
    return ClaudeCodeUsageStore(
        defaults: defaults.defaults,
        cacheURL: directory.file("usage.json"),
        migrateBridge: false,
        subscriptionCacheURL: directory.file("plan.json"),
        locateExecutable: { executable },
        subscriptionQuery: subscription,
        query: query
    )
}

@MainActor
@Suite("Claude Code usage store")
struct ClaudeCodeUsageStoreTests {
    @Test("Starting shows the cached query without running a new one")
    func startLoadsCache() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        let cached = usageSnapshot(at: Date())
        try ClaudeUsageQueryCache.write(cached, to: directory.file("usage.json"))
        let queries = CallLog<Bool>()
        let store = makeStore(defaults: defaults, directory: directory) {
            await queries.append(true)
            return cached
        }

        store.start()
        defer { store.stop() }

        #expect(store.isConnected)
        #expect(store.snapshot == cached && store.isCached && store.phase == .ready)
        #expect(await queries.values.isEmpty)
    }

    @Test("A refresh runs one query, caches it and updates the subscription plan")
    func refreshCachesResult() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        let result = usageSnapshot(at: Date(), usedFive: 40)
        let queries = CallLog<Bool>()
        let store = makeStore(
            defaults: defaults, directory: directory, subscription: { .max },
            query: {
                await queries.append(true)
                return result
            })
        store.start()
        defer { store.stop() }

        await store.userRefresh()

        #expect(await queries.values.count == 1)
        #expect(store.phase == .ready && !store.isCached)
        #expect(store.snapshot == result)
        #expect(try ClaudeUsageQueryCache.read(from: directory.file("usage.json")) == result)
        #expect(store.subscriptionPlan == .max && !store.isSubscriptionCached)
    }

    @Test("Without an installed CLI a refresh fails and never queries")
    func missingCLI() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        let queries = CallLog<Bool>()
        let store = makeStore(defaults: defaults, directory: directory, executable: nil) {
            await queries.append(true)
            return usageSnapshot(at: Date())
        }

        await store.userRefresh()

        #expect(!store.isInstalled)
        #expect(store.phase == .failed(ClaudeUsageQueryError.cliMissing.localizedDescription))
        #expect(await queries.values.isEmpty)
    }

    @Test("Cancelling a refresh discards its late result")
    func cancelDiscardsLateResult() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        let gate = Gate()
        let store = makeStore(defaults: defaults, directory: directory) {
            await gate.wait()  // Ignores cancellation, like a slow CLI.
            return usageSnapshot(at: Date())
        }
        store.start()
        defer { store.stop() }

        let refresh = Task { await store.userRefresh() }
        try await waitUntil("the query is in flight") { store.isLoading }
        store.cancelRefresh()
        #expect(!store.isLoading && store.phase == .idle)

        await gate.open()
        await refresh.value
        #expect(store.snapshot == nil && store.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: directory.file("usage.json").path))
    }

    @Test("Clearing removes the usage and plan caches")
    func clearRemovesCaches() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        try ClaudeUsageQueryCache.write(usageSnapshot(at: Date()), to: directory.file("usage.json"))
        try ClaudeCodeSubscriptionCache.write(.pro, to: directory.file("plan.json"))
        let store = makeStore(defaults: defaults, directory: directory) { usageSnapshot(at: Date()) }
        store.start()
        defer { store.stop() }
        #expect(store.hasQueryCache && store.snapshot != nil)

        try store.clearReports()

        #expect(!store.hasQueryCache)
        #expect(store.snapshot == nil && store.subscriptionPlan == nil && store.phase == .idle)
    }
}
