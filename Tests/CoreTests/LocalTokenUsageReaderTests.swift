import Foundation
import Testing

@testable import QuotAICore

@Suite("Local token activity")
struct LocalTokenUsageReaderTests {
    private let now = Date(timeIntervalSince1970: 1_710_072_000)  // March 10, 2024, 12:00 UTC
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        return calendar
    }

    @Test("Claude counts cached tokens and keeps one final usage value per message")
    func claudeUsage() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let custom = home.appendingPathComponent("custom-claude")
        let transcript = custom.appendingPathComponent("projects/project/chat.jsonl")
        let latest =
            #"{"timestamp":"2024-03-09T17:12:00.000Z","message":{"id":"msg_1","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":50,"cache_creation_input_tokens":8}}}"#
        try write(
            """
            {"timestamp":"2024-03-09T17:12:00.000Z","message":{"id":"msg_1","usage":{"input_tokens":10,"output_tokens":1,"cache_read_input_tokens":50,"cache_creation_input_tokens":8}}}
            \(latest)
            {"timestamp":"2024-03-09T10:00:00Z","message":{"id":"msg_2","usage":{"input_tokens":7,"output_tokens":3}}}
            """, to: transcript)
        try write(latest, to: custom.appendingPathComponent("projects/project/subagents/copy.jsonl"))
        try write(latest, to: home.appendingPathComponent(".claude/projects/ignored.jsonl"))

        let reader = LocalTokenUsageReader(home: home, claudeConfigDirectory: custom.path)
        let first = try await reader.read(.claudeCode, now: now, calendar: calendar)
        let activity = try #require(first.activity)
        #expect(!first.isPartial)
        #expect(
            activity.dailyUsageBuckets == [
                .init(startDate: "2024-03-09", tokens: 10),
                .init(startDate: "2024-03-10", tokens: 88)
            ])
        #expect(activity.summary?.lifetimeTokens == 98)
        #expect(activity.summary?.currentStreakDays == 2)

        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(
            contentsOf: Data(
                ("\n" + #"{"timestamp":"2024-03-10T01:00:00Z","message":{"id":"msg_3","usage":{"output_tokens":12}}}"#)
                    .utf8))
        try handle.close()
        let updated = try await reader.read(.claudeCode, now: now, calendar: calendar)
        #expect(updated.activity?.summary?.lifetimeTokens == 110)
        #expect(updated.activity?.dailyUsageBuckets.last?.tokens == 100)
    }

    @Test("Antigravity combines app and CLI usage without counting Gemini CLI or adding included cache twice")
    func antigravityUsage() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let event =
            #"{"created_at":"2024-03-09T17:00:00Z","input_tokens":10,"output_tokens":8,"cache_read_tokens":40,"thinking":"text"}"#
        try write(
            event + "\n" + #"{"created_at":"2024-03-09T17:02:00Z","input_tokens":"#,  // interrupted final write
            to: home.appendingPathComponent(".gemini/antigravity/brain/chat/.internal/logs/steps.jsonl"))
        try write(
            #"{"messages":[{"timestamp":"2024-03-09T18:00:00Z","usageMetadata":{"promptTokenCount":100,"cachedContentTokenCount":70,"candidatesTokenCount":20,"thoughtsTokenCount":7}},{"timestamp":"2024-03-09T18:02:00Z","usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":1,"totalTokenCount":15}}]}"#,
            to: home.appendingPathComponent(".gemini/antigravity-cli/sessions/session.json"))
        try write(event, to: home.appendingPathComponent(".gemini/tmp/project/chats/session.jsonl"))
        try write(event, to: home.appendingPathComponent(".gemini/antigravity/config.jsonl"))
        let aliased = home.appendingPathComponent(".antigravity-ide/logs/linked.jsonl")
        try FileManager.default.createDirectory(
            at: aliased.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: aliased, withDestinationURL: home.appendingPathComponent(".gemini/tmp/project/chats/session.jsonl"))

        let reader = LocalTokenUsageReader(home: home, claudeConfigDirectory: nil)
        let result = try await reader.read(.antigravity, now: now, calendar: calendar)
        #expect(result.activity?.dailyUsageBuckets == [.init(startDate: "2024-03-10", tokens: 200)])
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
}
