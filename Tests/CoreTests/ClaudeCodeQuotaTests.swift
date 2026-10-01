import Foundation
import Testing
@testable import QuotAICore

struct ClaudeCodeQuotaTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Official fields alone form a report, with conservative remaining percentage")
    func officialFields() throws {
        let snapshot = try #require(parse(input(usedFive: 25.1, usedSeven: 62)))
        #expect(snapshot.fiveHour?.quota.remainingPercent == 74)
        #expect(snapshot.sevenDay?.quota.remainingPercent == 38)
        #expect(snapshot.menuBarLines(for: .both, now: now) == ["5h ~74%", "7d ~38%"])
        #expect(snapshot.sessionFingerprint.count == 64)
        #expect(!snapshot.sessionFingerprint.contains("private-session"))
        #expect(snapshot.orderedReports.map(\.kind) == [.fiveHour, .sevenDay])
    }

    @Test("Identical windows cannot extend their own 30-minute display lifetime")
    func duplicatesAndIndependentWindows() throws {
        let original = try #require(parse(input(usedFive: 20, usedSeven: 30)))
        let duplicate = try #require(parse(input(usedFive: 20, usedSeven: 30), previous: original, at: now.addingTimeInterval(100)))
        #expect(duplicate.fiveHour?.firstObservedAt == now)
        #expect(duplicate.sevenDay?.firstObservedAt == now)
        let changed = try #require(parse(input(usedFive: 21, usedSeven: 30), previous: duplicate, at: now.addingTimeInterval(1_801)))
        #expect(changed.fiveHour?.firstObservedAt == now.addingTimeInterval(1_801))
        #expect(changed.sevenDay?.firstObservedAt == now)
        #expect(changed.displayableQuotas(at: now.addingTimeInterval(1_801)).map(\.kind) == [.fiveHour])
        #expect(changed.menuBarLines(for: .both, now: now.addingTimeInterval(1_801)) == ["5h ~79%", "7d --"])
    }

    @Test("Missing and invalid windows are dropped independently and never filled from a previous callback")
    func invalidWindows() throws {
        let previous = try #require(parse(input(usedFive: 20, usedSeven: 30)))
        let invalid: [Any] = [NSNull(), "wrong", ["used_percentage": -1, "resets_at": now.timeIntervalSince1970 + 3600],
            ["used_percentage": 101, "resets_at": now.timeIntervalSince1970 + 3600],
            ["used_percentage": true, "resets_at": now.timeIntervalSince1970 + 3600],
            ["used_percentage": "12", "resets_at": now.timeIntervalSince1970 + 3600],
            ["used_percentage": 12, "resets_at": true],
            ["used_percentage": 12, "resets_at": now.timeIntervalSince1970],
            ["used_percentage": 12, "resets_at": (now.timeIntervalSince1970 + 3600) * 1000],
            ["used_percentage": 12, "resets_at": now.timeIntervalSince1970 + 18_301],
            ["used_percentage": 12, "resets_at": now.timeIntervalSince1970 + 3_600.5]]
        for value in invalid {
            let data = try json(["session_id": "private-session", "rate_limits": ["five_hour": value, "seven_day": window(30, reset: now.addingTimeInterval(86_400))]])
            let snapshot = try #require(parse(data, previous: previous))
            #expect(snapshot.fiveHour == nil)
            #expect(snapshot.sevenDay?.usedPercentage == 30)
        }
        let missing = try #require(parse(input(usedFive: nil, usedSeven: 30), previous: previous))
        #expect(missing.fiveHour == nil)
        #expect(missing.menuBarLines(for: .both, now: now) == ["7d ~70%"])
        let none = try #require(parse(try json(["session_id": "private-session"]), previous: previous))
        #expect(none.orderedReports.isEmpty)
        #expect(none.menuBarLines(for: .both, now: now) == ["--"])
    }

    @Test("Malformed, oversized, or unidentifiable callbacks never create a report")
    func invalidRoots() throws {
        for data in [Data("{broken".utf8), Data("[]".utf8), Data("{\"session_id\":\"x\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":1e999,\"resets_at\":1800003600}}}".utf8),
                     try json([:]), try json(["session_id": ""]), try json(["session_id": " \n"]),
                     try json(["session_id": 42]), try json(["session_id": String(repeating: "a", count: 1_025)]),
                     Data(repeating: 32, count: ClaudeCodeRateLimitParser.inputLimit + 1)] {
            #expect(parse(data) == nil)
        }
    }

    @Test("Stale, expired, and future receipt clocks hide percentages on the same boundary")
    func displayBoundaries() throws {
        let snapshot = try #require(parse(input(usedFive: 20, usedSeven: 30)))
        #expect(snapshot.displayableQuotas(at: now.addingTimeInterval(1_799.99)).count == 2)
        #expect(snapshot.nextDisplayDeadline(after: now) == now.addingTimeInterval(1_800))
        #expect(snapshot.displayableQuotas(at: now.addingTimeInterval(1_800)).isEmpty)
        #expect(snapshot.nextDisplayDeadline(after: now.addingTimeInterval(1_800)) == nil)
        #expect(!snapshot.menuBarLines(for: .both, now: now.addingTimeInterval(1_800)).joined().contains("%"))
        #expect(snapshot.displayableQuotas(at: now.addingTimeInterval(-1)).isEmpty)
        #expect(snapshot.nextDisplayDeadline(after: now.addingTimeInterval(-1)) == nil)
        #expect(!snapshot.menuBarLines(for: .both, now: now.addingTimeInterval(-1)).joined().contains("%"))
        let expiring = ClaudeCodeQuotaReport(kind: .fiveHour, usedPercentage: 20, resetsAt: now.addingTimeInterval(10), firstObservedAt: now)
        #expect(!expiring.isDisplayable(at: now.addingTimeInterval(10)))
        let sooner = ClaudeCodeQuotaSnapshot(fiveHour: expiring, sevenDay: snapshot.sevenDay, sessionFingerprint: snapshot.sessionFingerprint, lastCallbackAt: now)
        #expect(sooner.nextDisplayDeadline(after: now) == now.addingTimeInterval(10))
        #expect(sooner.nextDisplayDeadline(after: now.addingTimeInterval(10)) == now.addingTimeInterval(1_800))
        #expect(!ClaudeCodeQuotaReport(kind: .fiveHour, usedPercentage: .nan, resetsAt: now.addingTimeInterval(10), firstObservedAt: now).isDisplayable(at: now))
    }

    @Test("Session selection stays pinned and missing selected sessions are unavailable")
    func selectionIsolation() throws {
        let first = try #require(parse(input(usedFive: 20, usedSeven: nil, session: "session-one")))
        let second = try #require(parse(input(usedFive: 80, usedSeven: nil, session: "session-two")))
        #expect(first.sessionFingerprint != second.sessionFingerprint)
        var selection = ClaudeCodeSessionSelection(selectedSessionID: first.sessionFingerprint)
        #expect(selection.resolve(in: [first]) == first)
        #expect(selection.resolve(in: [second, first]) == first)
        #expect(selection.resolve(in: [second]) == nil)
        selection.selectedSessionID = second.sessionFingerprint
        #expect(selection.resolve(in: [first, second]) == second)
        let candidate = try #require(parse(input(usedFive: 20, usedSeven: nil, session: "session-two"), previous: first, at: now.addingTimeInterval(60)))
        #expect(candidate.fiveHour?.firstObservedAt == now.addingTimeInterval(60))
    }

    @Test("Archive retains at most eight independent sessions and expires at 24 hours")
    func retention() throws {
        var archive = ClaudeCodeReportArchive(configurationFingerprint: "fixture")
        for i in 0..<10 {
            let snapshot = try #require(parse(input(usedFive: Double(i), usedSeven: nil, session: "session-\(i)")))
            archive.record(snapshot, now: now)
        }
        #expect(archive.snapshots.count == 8)
        #expect(archive.receiptHistory.count == 8)
        #expect(archive.retained(at: now.addingTimeInterval(86_399)).count == 8)
        #expect(archive.retained(at: now.addingTimeInterval(86_400)).isEmpty)
        #expect(archive.retained(at: now.addingTimeInterval(-1)).isEmpty)
    }

    @Test("Disk contains only whitelisted receipts, with private permissions and per-session throttle")
    func persistenceAndGapDeduplication() throws {
        let fixture = try ClaudeCodeTestFixture()
        defer { fixture.remove() }
        let state = try fixture.enable()
        var root = try #require(JSONSerialization.jsonObject(with: input(usedFive: 20, usedSeven: 30)) as? [String: Any])
        root["cwd"] = "PRIVATE-PATH"; root["transcript_path"] = "SECRET-TRANSCRIPT"; root["cost"] = ["private": 42]
        root["context_window"] = ["total_input_tokens": 12345]; root["model"] = ["id": "private-model"]
        #expect(try ClaudeCodeReportRepository.record(input: json(root), state: state, reportsURL: fixture.reports, now: now))
        let original = try Data(contentsOf: fixture.reports)
        #expect(try fixture.permissions(fixture.reports) == 0o600)
        let text = String(decoding: original, as: UTF8.self)
        for forbidden in ["PRIVATE-PATH", "SECRET-TRANSCRIPT", "private-session", "total_input_tokens", "private-model", "cost", "transcript_path", "cwd"] { #expect(!text.contains(forbidden)) }
        #expect(try !ClaudeCodeReportRepository.record(input: input(usedFive: 20, usedSeven: 30), state: state, reportsURL: fixture.reports, now: now.addingTimeInterval(59)))
        #expect(try Data(contentsOf: fixture.reports) == original)
        // A missing window must immediately disappear despite the throttle.
        #expect(try ClaudeCodeReportRepository.record(input: input(usedFive: nil, usedSeven: 30), state: state, reportsURL: fixture.reports, now: now.addingTimeInterval(60)))
        let absent = try ClaudeCodeReportRepository.read(configurationFingerprint: state.configurationFingerprint, reportsURL: fixture.reports)
        #expect(absent.snapshots.first?.fiveHour == nil)
        #expect(try ClaudeCodeReportRepository.record(input: input(usedFive: 20, usedSeven: 30), state: state, reportsURL: fixture.reports, now: now.addingTimeInterval(1_801)))
        let returned = try ClaudeCodeReportRepository.read(configurationFingerprint: state.configurationFingerprint, reportsURL: fixture.reports)
        #expect(returned.snapshots.first?.fiveHour?.firstObservedAt == now)
        #expect(returned.snapshots.first?.displayableQuotas(at: now.addingTimeInterval(1_801)).isEmpty == true)
        let otherConfiguration = try ClaudeCodeReportRepository.read(configurationFingerprint: "new-installation", reportsURL: fixture.reports)
        #expect(otherConfiguration.snapshots.isEmpty)
    }

    @Test("Invalid and symlink report files fail closed and clear never follows a symlink")
    func unsafeFiles() throws {
        let fixture = try ClaudeCodeTestFixture()
        defer { fixture.remove() }
        let state = try fixture.enable()
        for bad in [Data("{broken".utf8), Data(repeating: 32, count: ClaudeCodeReportRepository.fileLimit + 1)] {
            try bad.write(to: fixture.reports)
            #expect(throws: (any Error).self) { try ClaudeCodeReportRepository.read(configurationFingerprint: state.configurationFingerprint, reportsURL: fixture.reports) }
        }
        let target = fixture.root.appendingPathComponent("target.json")
        try Data("KEEP".utf8).write(to: target)
        try FileManager.default.removeItem(at: fixture.reports)
        try FileManager.default.createSymbolicLink(at: fixture.reports, withDestinationURL: target)
        #expect(throws: (any Error).self) { try ClaudeCodeReportRepository.clear(reportsURL: fixture.reports) }
        #expect(try Data(contentsOf: target) == Data("KEEP".utf8))
    }

    private func parse(_ data: Data, previous: ClaudeCodeQuotaSnapshot? = nil, at date: Date? = nil) -> ClaudeCodeQuotaSnapshot? {
        ClaudeCodeRateLimitParser.parse(data, previous: previous, sessionSalt: "fixture-salt", configurationFingerprint: "fixture-config", now: date ?? now)
    }
    private func window(_ used: Double, reset: Date) -> [String: Any] { ["used_percentage": used, "resets_at": reset.timeIntervalSince1970] }
    private func input(usedFive: Double?, usedSeven: Double?, session: String = "private-session") throws -> Data {
        var limits: [String: Any] = [:]
        if let usedFive { limits["five_hour"] = window(usedFive, reset: now.addingTimeInterval(3_600)) }
        if let usedSeven { limits["seven_day"] = window(usedSeven, reset: now.addingTimeInterval(86_400)) }
        return try json(["session_id": session, "rate_limits": limits])
    }
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
}
