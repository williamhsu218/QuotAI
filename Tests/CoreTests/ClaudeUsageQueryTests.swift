import Foundation
import Darwin
import Testing
@testable import QuotAICore

@Suite struct ClaudeUsageQueryTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-01T15:30:00Z")!
    private let lines = "Current session: 15% used · resets Oct 2 at 2:29am (Asia/Shanghai)\nCurrent week (all models): 9% used · resets Oct 7 at 9:59pm (Asia/Shanghai)"
    private func input(_ text: String, changes: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["type": "result", "subtype": "success", "is_error": false, "num_turns": 0, "total_cost_usd": 0, "modelUsage": [String: Any](), "result": text,
            "usage": ["input_tokens": 0, "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0]]
        value.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }
    @Test func officialZeroTurnOutputAndTimezone() throws {
        let snapshot = try ClaudeUsageQueryParser.parse(input(lines), at: now)
        #expect(snapshot.source == .usageQuery)
        #expect(snapshot.sessionFingerprint == "usage-query")
        #expect(snapshot.fiveHour?.quota.remainingPercent == 85)
        #expect(snapshot.sevenDay?.quota.remainingPercent == 91)
        #expect(snapshot.fiveHour?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-01T18:29:00Z"))
        #expect(snapshot.sevenDay?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-07T13:59:00Z"))
    }
    @Test func unchangedSuccessfulQueryRenewsReceiptAndHistoricalNumbersRemain() throws {
        let first = try ClaudeUsageQueryParser.parse(input(lines), at: now)
        let later = now.addingTimeInterval(1_801)
        #expect(first.isHistorical(at: later))
        #expect(first.displayableQuotas(at: later).count == 2)
        #expect(first.menuBarLines(for: .both, now: later) == ["5h ~85%", "7d ~91%"])
        let second = try ClaudeUsageQueryParser.parse(input(lines), at: later)
        #expect(second.lastCallbackAt == later)
        #expect(second.fiveHour?.firstObservedAt == later)
        #expect(!second.isHistorical(at: later))
        let reset = try #require(first.fiveHour?.resetsAt)
        #expect(first.menuBarLines(for: .both, now: reset) == ["5h --", "7d ~91%"])
        #expect(first.displayableQuotas(at: now.addingTimeInterval(-1)).isEmpty)
        let entries = ClaudeCodeReportDisplayTimeline.entries(for: first, from: now)
        #expect(entries.contains(now.addingTimeInterval(1_800.01)))
        #expect(entries.contains(reset.addingTimeInterval(0.01)))
    }
    @Test func partialAndFractionalOutputIsNeverFilledFromOtherReports() throws {
        let single = try ClaudeUsageQueryParser.parse(input("Current session: 23.5% used · resets Oct 2 at 2:29am (Asia/Shanghai)"), at: now)
        #expect(single.fiveHour?.quota.remainingPercent == 76)
        #expect(single.sevenDay == nil)
        let other = try ClaudeUsageQueryParser.parse(input("Current week (all models): 100% used · resets Oct 7 at 9:59pm (Asia/Shanghai)\nCurrent week (Opus): 90% used · resets Oct 7 at 9:59pm (Asia/Shanghai)"), at: now)
        #expect(other.fiveHour == nil)
        #expect(other.sevenDay?.quota.remainingPercent == 0)
    }
    @Test func zeroTurnCLI287OutputSupportsHourWithoutMinutes() throws {
        let queried = ISO8601DateFormatter().date(from: "2026-10-02T09:28:52Z")!
        let text = "You are currently using your subscription to power your Claude Code usage\n\nCurrent session: 0% used · resets Oct 2 at 10:20pm (Asia/Shanghai)\nCurrent week (all models): 10% used · resets Oct 7 at 10pm (Asia/Shanghai)"
        let value = try ClaudeUsageQueryParser.parse(input(text), at: queried)
        #expect(value.fiveHour?.quota.remainingPercent == 100)
        #expect(value.fiveHour?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-02T14:20:00Z"))
        #expect(value.sevenDay?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-07T14:00:00Z"))
    }
    @Test func missingResetDoesNotDiscardTheIndependentWindow() throws {
        let missingFive = lines.replacingOccurrences(of: "15% used · resets Oct 2 at 2:29am (Asia/Shanghai)", with: "0% used")
        let weekly = try ClaudeUsageQueryParser.parse(input(missingFive), at: now)
        #expect(weekly.fiveHour == nil)
        #expect(weekly.sevenDay?.quota.remainingPercent == 91)
        #expect(weekly.menuBarLines(for: .fiveHour, now: now) == ["5h --"])
        let missingSeven = lines.replacingOccurrences(of: "9% used · resets Oct 7 at 9:59pm (Asia/Shanghai)", with: "0% used")
        let session = try ClaudeUsageQueryParser.parse(input(missingSeven), at: now)
        #expect(session.fiveHour?.quota.remainingPercent == 85)
        #expect(session.sevenDay == nil)
    }
    @Test func expiredWindowsAreOmittedWithoutRollingResetForward() throws {
        for oldReset in ["Oct 1 at 9pm", "Today at 9pm", "Oct 1 at 1am", "Today at 1am"] {
            let value = try ClaudeUsageQueryParser.parse(input(lines.replacingOccurrences(of: "Oct 2 at 2:29am", with: oldReset)), at: now)
            #expect(value.fiveHour == nil)
            #expect(value.sevenDay?.quota.remainingPercent == 91)
            #expect(value.displayableQuotas(at: now).map(\.kind) == [.sevenDay])
        }
    }
    @Test func noActiveWindowsIsAValidEmptySnapshotAndClearsCache() throws {
        let empty = try ClaudeUsageQueryParser.parse(input("Current session: 0% used\nCurrent week (all models): 0% used"), at: now)
        #expect(empty.orderedReports.isEmpty)
        #expect(empty.menuBarLines(for: .both, now: now) == ["--"])
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
        let folder = URL(fileURLWithPath: String(cString: resolved), isDirectory: true).appendingPathComponent(UUID().uuidString)
        free(resolved)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cache.json")
        try ClaudeUsageQueryCache.write(ClaudeUsageQueryParser.parse(input(lines), at: now), to: url)
        try ClaudeUsageQueryCache.write(empty, to: url)
        #expect(try ClaudeUsageQueryCache.read(from: url) == empty)
        #expect(try ClaudeUsageQueryCache.read(from: url)?.orderedReports.isEmpty == true)
        #expect(throws: ClaudeUsageQueryError.invalidOutput) {
            try ClaudeUsageQueryParser.parse(input("Current session: 0% used\nCurrent session: 0% used"), at: now)
        }
        #expect(throws: ClaudeUsageQueryError.modelResponse) {
            try ClaudeUsageQueryParser.parse(input("Current session: 0% used", changes: ["num_turns": 1]), at: now)
        }
    }
    @Test func modelRepliesAndCostAreRejected() throws {
        for changes: [String: Any] in [["num_turns": 1], ["num_turns": false], ["total_cost_usd": 0.1], ["modelUsage": ["claude-opus-5-5": ["inputTokens": 1]]], ["usage": ["output_tokens": 1]]] {
            #expect(throws: ClaudeUsageQueryError.modelResponse) { try ClaudeUsageQueryParser.parse(input(lines, changes: changes), at: now) }
        }
        #expect(throws: ClaudeUsageQueryError.noQuota) { try ClaudeUsageQueryParser.parse(input("You are currently using your subscription to power your Claude Code usage"), at: now) }
        #expect(throws: ClaudeUsageQueryError.loginRequired) { try ClaudeUsageQueryParser.parse(input("Please log in", changes: ["is_error": true]), at: now) }
    }
    @Test func invalidAndUnexpectedTextFailsClosed() throws {
        for text in [lines + "\n" + lines, lines.replacingOccurrences(of: "15%", with: "101%"), lines.replacingOccurrences(of: "resets", with: "unknown")] {
            #expect(throws: ClaudeUsageQueryError.invalidOutput) { try ClaudeUsageQueryParser.parse(input(text), at: now) }
        }
        for text in [lines.replacingOccurrences(of: "Asia/Shanghai", with: "Unknown/Zone"), lines.replacingOccurrences(of: "2:29am", with: "25:29am"), lines.replacingOccurrences(of: "Oct 2", with: "Feb 30"), lines.replacingOccurrences(of: "Oct 2", with: "Oct 12")] {
            #expect(throws: ClaudeUsageQueryError.invalidResetTime) { try ClaudeUsageQueryParser.parse(input(text), at: now) }
        }
        #expect(throws: ClaudeUsageQueryError.invalidOutput) { try ClaudeUsageQueryParser.parse(Data("not JSON".utf8), at: now) }
        #expect(throws: ClaudeUsageQueryError.oversizedOutput) { try ClaudeUsageQueryParser.parse(Data(repeating: 65, count: ClaudeUsageQueryParser.outputLimit + 1), at: now) }
    }
    @Test func yearRolloverAndAmbiguousDST() throws {
        let december = ISO8601DateFormatter().date(from: "2026-12-31T15:40:00Z")!
        let next = try ClaudeUsageQueryParser.parse(input("Current session: 15% used · resets Jan 1 at 12:05am (Asia/Shanghai)"), at: december)
        #expect(next.fiveHour?.resetsAt == ISO8601DateFormatter().date(from: "2026-12-31T16:05:00Z"))
        let autumn = ISO8601DateFormatter().date(from: "2026-11-01T04:30:00Z")!
        #expect(throws: ClaudeUsageQueryError.invalidResetTime) { try ClaudeUsageQueryParser.parse(input("Current session: 15% used · resets Nov 1 at 1:30am (America/New_York)"), at: autumn) }
    }
    @Test func privateCacheContainsOnlyQueryWindows() throws {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
        let folder = URL(fileURLWithPath: String(cString: resolved), isDirectory: true).appendingPathComponent(UUID().uuidString)
        free(resolved)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cache.json")
        let snapshot = try ClaudeUsageQueryParser.parse(input(lines), at: now)
        try ClaudeUsageQueryCache.write(snapshot, to: url)
        #expect(try ClaudeUsageQueryCache.read(from: url) == snapshot)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("Current session"))
        #expect(!text.contains("modelUsage"))
        #expect(!text.contains("input_tokens"))
        let link = folder.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: (any Error).self) { try ClaudeUsageQueryCache.clear(at: link) }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
