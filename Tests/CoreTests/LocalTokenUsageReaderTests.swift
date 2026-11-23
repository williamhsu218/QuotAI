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

    @Test("Deleting an Antigravity conversation archives its tokens and adds new conversations accurately")
    func antigravityPreservesDeletedConversationHistory() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ledgerURL = home.appendingPathComponent("Support/token-activity-v1.json")

        let brain = home.appendingPathComponent(".gemini/antigravity/brain")
        let transcript = ".system_generated/logs/transcript.jsonl"
        let convA = brain.appendingPathComponent("conv-a")
        let convB = brain.appendingPathComponent("conv-b")
        let convC = brain.appendingPathComponent("conv-c")
        let firstConversation = #"{"created_at":"2024-03-09T17:00:00Z","total_tokens":100}"#
        try write(firstConversation, to: convA.appendingPathComponent(transcript))
        try write(
            #"{"created_at":"2024-03-09T18:00:00Z","input_tokens":30,"output_tokens":20}"#,
            to: convB.appendingPathComponent(transcript))

        let firstReader = LocalTokenUsageReader(home: home, claudeConfigDirectory: nil, ledgerURL: ledgerURL)
        let first = try await firstReader.read(.antigravity, now: now, calendar: calendar)
        #expect(first.activity?.dailyUsageBuckets == [.init(startDate: "2024-03-10", tokens: 150)])
        #expect(!first.hasArchivedHistory)

        // Delete conversation A and create a new conversation C on the same day.
        try FileManager.default.removeItem(at: convA)
        try write(
            #"{"created_at":"2024-03-09T19:00:00Z","input_tokens":50,"output_tokens":30}"#,
            to: convC.appendingPathComponent(transcript))

        // Simulate app restart with a fresh reader loading from the persisted ledger.
        let restartedReader = LocalTokenUsageReader(home: home, claudeConfigDirectory: nil, ledgerURL: ledgerURL)
        let afterDelete = try await restartedReader.read(.antigravity, now: now, calendar: calendar)
        #expect(afterDelete.activity?.dailyUsageBuckets == [.init(startDate: "2024-03-10", tokens: 230)])
        #expect(afterDelete.activity?.summary?.lifetimeTokens == 230)
        #expect(afterDelete.hasArchivedHistory)

        // Verify privacy: 0600 permissions and no raw file paths in the ledger JSON.
        let attributes = try FileManager.default.attributesOfItem(atPath: ledgerURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)
        let rawLedger = try String(contentsOf: ledgerURL, encoding: .utf8)
        #expect(!rawLedger.contains("conv-a"))
        #expect(!rawLedger.contains("conv-b"))
        #expect(!rawLedger.contains("transcript.jsonl"))

        try write(firstConversation, to: convA.appendingPathComponent(transcript))
        let restored = try await restartedReader.read(.antigravity, now: now, calendar: calendar)
        #expect(restored.activity?.summary?.lifetimeTokens == 230)
        #expect(!restored.hasArchivedHistory)

        // Deleting all remaining conversations still preserves total recorded tokens.
        try FileManager.default.removeItem(at: convA)
        try FileManager.default.removeItem(at: convB)
        try FileManager.default.removeItem(at: convC)
        let allDeleted = try await restartedReader.read(.antigravity, now: now, calendar: calendar)
        #expect(allDeleted.activity?.dailyUsageBuckets == [.init(startDate: "2024-03-10", tokens: 230)])
        #expect(allDeleted.hasArchivedHistory)

        // Clearing history resets to current live disk state (empty).
        try await restartedReader.clearHistory()
        #expect(await !restartedReader.hasSavedHistory())
        let afterClear = try await restartedReader.read(.antigravity, now: now, calendar: calendar)
        #expect(afterClear.activity == nil && !afterClear.hasArchivedHistory)
    }

    @Test("Claude deletion archival avoids double-counting duplicate subagent messages")
    func claudeDeletionArchivalDeduplicatesMessages() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ledgerURL = home.appendingPathComponent("Support/token-activity-v1.json")
        let custom = home.appendingPathComponent("custom-claude")
        let chat = custom.appendingPathComponent("projects/project/chat.jsonl")
        let subagentCopy = custom.appendingPathComponent("projects/project/subagents/copy.jsonl")
        let message =
            #"{"timestamp":"2024-03-09T17:12:00.000Z","message":{"id":"msg_1","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":50,"cache_creation_input_tokens":8}}}"#
        try write(message, to: chat)
        try write(message, to: subagentCopy)

        let reader = LocalTokenUsageReader(home: home, claudeConfigDirectory: custom.path, ledgerURL: ledgerURL)
        let initial = try await reader.read(.claudeCode, now: now, calendar: calendar)
        #expect(initial.activity?.summary?.lifetimeTokens == 88)

        try FileManager.default.removeItem(at: chat)
        let restarted = LocalTokenUsageReader(home: home, claudeConfigDirectory: custom.path, ledgerURL: ledgerURL)
        let afterChatRemoved = try await restarted.read(.claudeCode, now: now, calendar: calendar)
        #expect(afterChatRemoved.activity?.summary?.lifetimeTokens == 88)
        #expect(!afterChatRemoved.hasArchivedHistory)

        try FileManager.default.removeItem(at: subagentCopy)
        let bothRemoved = try await restarted.read(.claudeCode, now: now, calendar: calendar)
        #expect(bothRemoved.activity?.summary?.lifetimeTokens == 88)
        #expect(bothRemoved.hasArchivedHistory)
        let rawLedger = try String(contentsOf: ledgerURL, encoding: .utf8)
        #expect(!rawLedger.contains("msg_1"))
    }

    @Test("A symlink-redirected root does not falsely archive tracked files")
    func unhealthyRootDoesNotFalselyArchive() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ledgerURL = home.appendingPathComponent("Support/token-activity-v1.json")
        let root = home.appendingPathComponent(".gemini/antigravity")
        let movedRoot = home.appendingPathComponent("moved-antigravity")
        let conv = root.appendingPathComponent("brain/chat/.system_generated/logs/transcript.jsonl")
        try write(#"{"created_at":"2024-03-09T17:00:00Z","input_tokens":80,"output_tokens":40}"#, to: conv)

        let reader = LocalTokenUsageReader(home: home, claudeConfigDirectory: nil, ledgerURL: ledgerURL)
        let initial = try await reader.read(.antigravity, now: now, calendar: calendar)
        #expect(initial.activity?.summary?.lifetimeTokens == 120)

        // Replace root with a symlink temporarily; reader must mark partial and NOT archive.
        try FileManager.default.moveItem(at: root, to: movedRoot)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: movedRoot)
        let redirected = try await reader.read(.antigravity, now: now, calendar: calendar)
        #expect(redirected.isPartial)
        #expect(!redirected.hasArchivedHistory)
        #expect(redirected.activity?.summary?.lifetimeTokens == 120)

        // Restore real directory; total must remain 120 (not 240).
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: movedRoot, to: root)
        let restored = try await reader.read(.antigravity, now: now, calendar: calendar)
        #expect(!restored.isPartial && !restored.hasArchivedHistory)
        #expect(restored.activity?.summary?.lifetimeTokens == 120)
    }

    @Test("A failed token ledger write is retried even if the logs are unchanged")
    func tokenLedgerRetriesWrite() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Support")
        let ledgerURL = support.appendingPathComponent("token-activity-v1.json")
        let transcript = home.appendingPathComponent(".gemini/antigravity/sessions/chat.jsonl")
        try write("blocks the directory", to: support)
        try write(#"{"created_at":"2024-03-09T17:00:00Z","input_tokens":60,"output_tokens":40}"#, to: transcript)

        let reader = LocalTokenUsageReader(home: home, claudeConfigDirectory: nil, ledgerURL: ledgerURL)
        let first = try await reader.read(.antigravity, now: now, calendar: calendar)
        #expect(first.isPartial && first.activity?.summary?.lifetimeTokens == 100)
        try FileManager.default.removeItem(at: support)

        let retried = try await reader.read(.antigravity, now: now, calendar: calendar)
        #expect(!retried.isPartial && retried.activity == first.activity)
        #expect(FileManager.default.fileExists(atPath: ledgerURL.path))

        try FileManager.default.removeItem(at: transcript)
        let restarted = LocalTokenUsageReader(home: home, claudeConfigDirectory: nil, ledgerURL: ledgerURL)
        let archived = try await restarted.read(.antigravity, now: now, calendar: calendar)
        #expect(archived.hasArchivedHistory && archived.activity == retried.activity)
    }

    @Test("An unreadable token ledger is preserved while live totals remain available")
    func tokenLedgerPreservesUnreadableFile() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ledgerURL = home.appendingPathComponent("Support/token-activity-v1.json")
        let transcript = home.appendingPathComponent(".gemini/antigravity/sessions/chat.jsonl")
        try write("unrecognized ledger", to: ledgerURL)
        try write(#"{"created_at":"2024-03-09T17:00:00Z","input_tokens":100}"#, to: transcript)

        let reader = LocalTokenUsageReader(home: home, claudeConfigDirectory: nil, ledgerURL: ledgerURL)
        let result = try await reader.read(.antigravity, now: now, calendar: calendar)
        #expect(result.isPartial && result.activity?.summary?.lifetimeTokens == 100)
        #expect(try String(contentsOf: ledgerURL, encoding: .utf8) == "unrecognized ledger")
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
