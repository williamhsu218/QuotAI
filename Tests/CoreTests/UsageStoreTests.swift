import Foundation
import Testing

@testable import QuotAICore

private struct FetchCall: Equatable, Sendable {
    let customPath: String?
    let confirmsEmptyResetCredits: Bool
}

/// Whole-second dates survive the cache's ISO 8601 round trip unchanged.
private func codexSnapshot(resetCount: Int, remaining: Int = 82) -> UsageSnapshot {
    let fetched = Date(timeIntervalSince1970: 1_800_000_000)
    return UsageSnapshot(
        fetchedAt: fetched,
        fiveHour: QuotaWindow(
            kind: .fiveHour, remainingPercent: remaining, resetsAt: fetched.addingTimeInterval(3_600)),
        sevenDay: nil,
        availableResetCount: resetCount,
        resetCredits: (0..<resetCount).map {
            ResetCredit(
                grantedAt: fetched.addingTimeInterval(Double(-$0) * 86_400), expiresAt: nil, status: "available")
        }
    )
}

@MainActor
@Suite("Codex usage store")
struct UsageStoreTests {
    @Test("Without previous reset credits a refresh reads once and caches the result")
    func refreshWithoutPreviousCredits() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        defaults.defaults.set("/opt/codex/bin/codex", forKey: DefaultsKey.codexBinaryPath)
        let cache = directory.file("usage-snapshot.json")
        let calls = CallLog<FetchCall>()
        let store = UsageStore(defaults: defaults.defaults, snapshotURL: cache) { path, confirms in
            await calls.append(FetchCall(customPath: path, confirmsEmptyResetCredits: confirms))
            return codexSnapshot(resetCount: 0)
        }
        #expect(store.snapshot == nil && store.phase == .idle)

        await store.refresh()

        #expect(await calls.values == [FetchCall(customPath: "/opt/codex/bin/codex", confirmsEmptyResetCredits: false)])
        #expect(store.phase == .ready)
        #expect(store.snapshot == codexSnapshot(resetCount: 0))
        #expect(try LocalSnapshotStore.load(from: cache) == store.snapshot)
    }

    @Test("Previously held reset credits are confirmed once before they are cleared")
    func refreshConfirmsPreviousCredits() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        let cache = directory.file("usage-snapshot.json")
        try LocalSnapshotStore.save(codexSnapshot(resetCount: 2), to: cache)
        let calls = CallLog<Bool>()
        let store = UsageStore(defaults: defaults.defaults, snapshotURL: cache) { _, confirms in
            await calls.append(confirms)
            return codexSnapshot(resetCount: 0)
        }
        #expect(store.snapshot?.availableResetCount == 2 && store.phase == .ready)

        await store.refresh()
        #expect(await calls.values == [true])
        #expect(store.snapshot?.availableResetCount == 0)

        // Credits are now known to be empty, so later refreshes read once.
        await store.refresh()
        #expect(await calls.values == [true, false])
    }

    @Test("A failed refresh keeps the cached snapshot and reports the error")
    func failedRefreshKeepsCache() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let defaults = try IsolatedDefaults()
        defer { defaults.remove() }
        let cache = directory.file("usage-snapshot.json")
        let cached = codexSnapshot(resetCount: 1, remaining: 40)
        try LocalSnapshotStore.save(cached, to: cache)
        let store = UsageStore(defaults: defaults.defaults, snapshotURL: cache) { _, _ in
            throw CodexAppServerClientError.updateRequired
        }

        await store.refresh()

        let message = try #require(CodexAppServerClientError.updateRequired.errorDescription)
        #expect(store.phase == .failed(message))
        #expect(store.snapshot == cached)
        #expect(store.statusMessage(at: Date()).contains(message))
        #expect(try LocalSnapshotStore.load(from: cache) == cached)
    }
}
