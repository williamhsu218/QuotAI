import Foundation

private enum ProbeFailure: Error { case unavailable, assertion(String) }

private actor Responses {
    var results: [Result<AntigravityQuotaSnapshot, ProbeFailure>]
    init(_ results: [Result<AntigravityQuotaSnapshot, ProbeFailure>]) { self.results = results }
    func next() throws -> AntigravityQuotaSnapshot { try results.removeFirst().get() }
}

private actor DelayedResponse {
    var continuation: CheckedContinuation<AntigravityQuotaSnapshot, Never>?
    func fetch() async -> AntigravityQuotaSnapshot {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: AntigravityQuotaFixtures.snapshot("denied")); continuation = nil }
    var isWaiting: Bool { continuation != nil }
}

@main
@MainActor
struct AntigravityQuotaProbe {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ProbeFailure.assertion(message) }
    }

    static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            let snapshot = try await AntigravityQuotaClient().fetch()
            let summary: [String: Any] = [
                "thirdPartyAvailability": snapshot.thirdPartyAvailability.rawValue,
                "argonAvailability": snapshot.argonAvailability.rawValue,
                "displayGroups": snapshot.displayGroups.map { group in
                    ["id": group.id, "windows": group.orderedQuotas.map {
                        ["kind": $0.kind.rawValue, "remaining": $0.remainingPercent,
                         "resetsAt": $0.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""] as [String: Any]
                    }] as [String: Any]
                }
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self))
            return
        }

        let suite = "QuotAI.access-probe." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = [AntigravityQuotaGroup.menuBarGroupDefaultsKey, AntigravityQuotaGroup.panelGroupDefaultsKey]
        for key in keys { defaults.set("3p", forKey: key) }
        let responses = Responses([
            .success(AntigravityQuotaFixtures.snapshot("available")), .failure(.unavailable),
            .success(AntigravityQuotaFixtures.snapshot("unknown")),
            .success(AntigravityQuotaFixtures.snapshot("denied")),
            .success(AntigravityQuotaFixtures.snapshot("exhausted")),
            .success(AntigravityQuotaFixtures.snapshot("available"))
        ])
        let store = AntigravityUsageStore(defaults: defaults, fetchSnapshot: { try await responses.next() }, installationDetector: { true })
        store.start()
        for _ in 0..<100 where store.phase == .idle || store.phase == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(store.phase == .ready, "Initial live-style refresh failed")
        try require(store.snapshot?.group(id: "3p")?.fiveHour?.remainingPercent == 44, "Available pool lost its quota")
        await store.refresh()
        try require(store.snapshot == nil, "A failed refresh retained old quota")
        guard case .failed = store.phase else { throw ProbeFailure.assertion("Missing failure state") }
        try require(keys.allSatisfy { defaults.string(forKey: $0) == "3p" }, "Failure changed preferences")
        await store.refresh()
        try require(store.snapshot?.group(id: "3p")?.orderedQuotas.isEmpty == true, "Unknown permission exposed quota")
        try require(keys.allSatisfy { defaults.string(forKey: $0) == "3p" }, "Unknown permission caused fallback")
        await store.refresh()
        try require(store.snapshot?.panelGroups.map(\.id) == ["gemini"], "Denied pool is visible")
        try require(keys.allSatisfy { defaults.string(forKey: $0) == "gemini" }, "Both selections did not fall back")
        await store.refresh()
        try require(store.snapshot?.panelGroups.count == 2, "Exhaustion hid the third-party tab")
        try require(store.snapshot?.group(id: "3p")?.isExhausted == true, "Exhaustion state is missing")
        await store.refresh()
        try require(store.snapshot?.group(id: "3p")?.fiveHour?.remainingPercent == 44, "Read recovery did not restore quota")
        store.stop()
        try require(store.snapshot == nil && store.phase == .idle, "Stop retained data")

        let delayed = DelayedResponse()
        let stopped = AntigravityUsageStore(defaults: defaults, fetchSnapshot: { await delayed.fetch() }, installationDetector: { true })
        for key in keys { defaults.set("3p", forKey: key) }
        stopped.start()
        for _ in 0..<100 {
            if await delayed.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        stopped.stop()
        await delayed.finish()
        try await Task.sleep(for: .milliseconds(30))
        try require(stopped.snapshot == nil && stopped.phase == .idle, "Late result escaped stop generation")
        try require(keys.allSatisfy { defaults.string(forKey: $0) == "3p" }, "Late denial overwrote preferences")

        let argonResponses = Responses([
            .success(AntigravityQuotaFixtures.snapshot("argon")), .failure(.unavailable),
            .success(AntigravityQuotaFixtures.snapshot("argon-unknown")),
            .success(AntigravityQuotaFixtures.snapshot("argon-exhausted")),
            .success(AntigravityQuotaFixtures.snapshot("argon-shared")),
            .success(AntigravityQuotaFixtures.snapshot("argon-denied")),
            .success(AntigravityQuotaFixtures.snapshot("argon"))
        ])
        for key in keys { defaults.set(AntigravityQuotaTab.argon.rawValue, forKey: key) }
        let argon = AntigravityUsageStore(defaults: defaults, fetchSnapshot: { try await argonResponses.next() }, installationDetector: { true })
        argon.start()
        for _ in 0..<100 where argon.phase == .idle || argon.phase == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(argon.snapshot?.panelGroup(id: AntigravityQuotaTab.argon.rawValue)?.orderedQuotas.map(\.kind) == [.sevenDay], "Argon lost its weekly-only quota")
        await argon.refresh()
        try require(argon.snapshot == nil && keys.allSatisfy { defaults.string(forKey: $0) == AntigravityQuotaTab.argon.rawValue }, "Argon failure retained data or changed preferences")
        await argon.refresh()
        try require(argon.snapshot?.panelGroup(id: AntigravityQuotaTab.argon.rawValue)?.orderedQuotas.isEmpty == true, "Unknown Argon access exposed quota")
        await argon.refresh()
        try require(argon.snapshot?.panelGroup(id: AntigravityQuotaTab.argon.rawValue)?.isExhausted == true, "Exhaustion hid Argon")
        await argon.refresh()
        try require(argon.snapshot?.panelGroups.contains { $0.id == AntigravityQuotaTab.argon.rawValue } == false, "Shared quota fabricated an Argon pool")
        try require(keys.allSatisfy { defaults.string(forKey: $0) == AntigravityQuotaTab.argon.rawValue }, "Shared or unknown quota rewrote Argon preferences")
        await argon.refresh()
        try require(keys.allSatisfy { defaults.string(forKey: $0) == "gemini" }, "Argon denial did not reconcile both selections")
        await argon.refresh()
        try require(argon.snapshot?.panelGroups.count == 3, "Argon access recovery did not restore all pools")
        argon.stop()
        print("PASS: success, failure, unknown access, denial fallback, exhaustion, recovery, stop, late result; isolated defaults only")
        print("PASS: Argon weekly-only, failure, unknown, exhaustion, shared-pool, denial and recovery; isolated defaults only")
    }
}
