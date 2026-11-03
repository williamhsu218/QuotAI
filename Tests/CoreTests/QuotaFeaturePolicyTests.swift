import Foundation
import Testing

@testable import QuotAICore

private func featureSample(
    _ percent: Int, at now: Date, reset: Date? = nil, historical: Bool = false
) -> ProviderQuotaSnapshot {
    .init(
        provider: .codex, providerName: "Codex", fetchedAt: now,
        groups: [
            .init(id: "default", name: "", quotas: [.init(kind: .fiveHour, remainingPercent: percent, resetsAt: reset)])
        ],
        isHistorical: historical)
}

@Suite("Quota feature policies")
struct QuotaFeaturePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Startup is a baseline; low-quota crossings notify once until meaningful recovery")
    func lowNotifications() {
        var policy = QuotaNotificationPolicy()
        #expect(policy.evaluate([featureSample(50, at: now)], at: now).isEmpty)
        #expect(
            policy.evaluate([featureSample(19, at: now.addingTimeInterval(60))], at: now.addingTimeInterval(60)).map(
                \.kind) == [.low])
        #expect(
            policy.evaluate([featureSample(18, at: now.addingTimeInterval(120))], at: now.addingTimeInterval(120))
                .isEmpty)
        #expect(
            policy.evaluate([featureSample(21, at: now.addingTimeInterval(180))], at: now.addingTimeInterval(180))
                .isEmpty)
        #expect(
            policy.evaluate([featureSample(19, at: now.addingTimeInterval(240))], at: now.addingTimeInterval(240))
                .isEmpty)
        _ = policy.evaluate([featureSample(30, at: now.addingTimeInterval(300))], at: now.addingTimeInterval(300))
        #expect(
            policy.evaluate([featureSample(10, at: now.addingTimeInterval(360))], at: now.addingTimeInterval(360)).count
                == 1)
    }

    @Test("A reset requires a fresh response confirming the next window")
    func resetConfirmation() {
        var policy = QuotaNotificationPolicy()
        let reset = now.addingTimeInterval(60)
        _ = policy.evaluate([featureSample(10, at: now, reset: reset)], at: now)
        #expect(policy.evaluate([featureSample(10, at: now, reset: reset)], at: now.addingTimeInterval(120)).isEmpty)
        let fresh = now.addingTimeInterval(180)
        #expect(
            policy.evaluate([featureSample(100, at: fresh, reset: fresh.addingTimeInterval(18_000))], at: fresh).map(
                \.kind) == [.reset])
    }

    @Test("Historical, stale and future samples cannot send quota notifications")
    func invalidNotificationSources() {
        var policy = QuotaNotificationPolicy()
        _ = policy.evaluate([featureSample(50, at: now)], at: now)
        #expect(
            policy.evaluate(
                [featureSample(1, at: now.addingTimeInterval(60), historical: true)], at: now.addingTimeInterval(60)
            ).isEmpty)
        #expect(
            policy.evaluate([featureSample(1, at: now.addingTimeInterval(120))], at: now.addingTimeInterval(900))
                .isEmpty)
        #expect(policy.evaluate([featureSample(1, at: now.addingTimeInterval(900))], at: now).isEmpty)
    }

    @Test("History coalesces each minute, survives reload and uses private file permissions")
    func historyPersistence() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("insights/history.json")
        let ledger = QuotaHistoryLedger(url: url)
        _ = try await ledger.record([featureSample(50, at: now)], at: now)
        let values = try await ledger.record(
            [featureSample(40, at: now.addingTimeInterval(5))], at: now.addingTimeInterval(5))
        #expect(values.count == 1 && values.first?.remainingPercent == 40)
        let reloaded = try await QuotaHistoryLedger(url: url).load(at: now.addingTimeInterval(5))
        #expect(reloaded == values)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        try await ledger.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try await ledger.load(at: now).isEmpty)
    }

    @Test("History caps size, prunes retention and skips cached or expired quota")
    func historyBounds() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let ledger = QuotaHistoryLedger(url: directory.file("history.json"), maximumSamples: 2, retention: 180)
        for offset in [0, 60, 120] {
            let date = now.addingTimeInterval(Double(offset))
            _ = try await ledger.record([featureSample(50, at: date)], at: date)
        }
        #expect(try await ledger.load(at: now.addingTimeInterval(120)).count == 2)
        let date = now.addingTimeInterval(180)
        let skipped = try await ledger.record(
            [
                featureSample(50, at: date, reset: date.addingTimeInterval(-1)),
                featureSample(50, at: date, historical: true)
            ], at: date)
        #expect(skipped.count == 2)
        #expect(try await ledger.load(at: now.addingTimeInterval(400)).isEmpty)
    }

    @Test("Widget values disappear at reset and old samples are explicitly stale")
    func widgetExpiry() {
        let value = WidgetQuotaRow(
            id: "codex/5h", providerID: "codex", title: "Codex", window: "5h", remainingPercent: 0,
            resetsAt: now.addingTimeInterval(60), fetchedAt: now, historical: false)
        #expect(value.displayable(at: now))
        #expect(!value.displayable(at: now.addingTimeInterval(60)))
        #expect(value.isStale(at: now.addingTimeInterval(1_801)))
    }

    @Test("Widget storage rejects unknown schemas and unbounded payloads")
    func widgetValidation() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("widget.json")
        try PrivateJSONFile.write(SharedWidgetSnapshot(version: 99, generatedAt: now, rows: []), to: url)
        #expect(throws: (any Error).self) { try WidgetSharedStore.read(from: url) }
        try PrivateJSONFile.write(SharedWidgetSnapshot(version: 1, generatedAt: now, rows: []), to: url)
        #expect(try WidgetSharedStore.read(from: url).rows.isEmpty)
    }
}
