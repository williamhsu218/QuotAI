import Darwin
import Foundation

actor QueryCounter {
    var count = 0
    func fetch(_ snapshot: ClaudeCodeQuotaSnapshot) async -> ClaudeCodeQuotaSnapshot {
        count += 1
        try? await Task.sleep(for: .milliseconds(300)) // Deliberately ignores cancellation to test the store's generation gate.
        return snapshot
    }
}

@main struct ClaudeUsageQueryProbe {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/query-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if CommandLine.arguments.contains("--live") {
            let value = try await ClaudeUsageQueryClient.fetch()
            print("LIVE /usage parsed: " + value.menuBarLines(for: .both).joined(separator: " · "))
            print("No raw result, account data or session ID persisted.")
            return
        }
        let now = Date()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "MMM d 'at' h:mma"; formatter.amSymbol = "am"; formatter.pmSymbol = "pm"
        let text = "Current session: 15% used · resets \(formatter.string(from: now.addingTimeInterval(3_600))) (Asia/Shanghai)\nCurrent week (all models): 9% used · resets \(formatter.string(from: now.addingTimeInterval(86_400))) (Asia/Shanghai)"
        let data = try JSONSerialization.data(withJSONObject: ["type": "result", "subtype": "success", "is_error": false, "num_turns": 0, "total_cost_usd": 0, "modelUsage": [String: Any](), "result": text])
        let snapshot = try ClaudeUsageQueryParser.parse(data, at: now)
        func fixture(_ name: String, body: String) throws -> URL {
            let file = directory.appendingPathComponent(name)
            try ("#!/usr/bin/python3\nimport sys, time, base64\n" + body).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return file
        }
        let valid = try fixture("valid", body: "assert sys.argv[1:3] == ['-p', '/usage']\nassert '--no-session-persistence' in sys.argv and '--strict-mcp-config' in sys.argv\nsys.stdout.buffer.write(base64.b64decode('\(data.base64EncodedString())'))\n")
        let actual = try await ClaudeUsageQueryClient.fetch(executable: valid)
        precondition(actual.fiveHour?.quota.remainingPercent == 85 && actual.sevenDay?.quota.remainingPercent == 91)
        let pidFile = directory.appendingPathComponent("child-pid")
        let slow = try fixture("slow", body: "import os\nopen('\(pidFile.path)', 'w').write(str(os.getpid()))\ntime.sleep(10)\n")
        do { _ = try await ClaudeUsageQueryClient.fetch(executable: slow, timeout: 0.5); fatalError("Expected timeout") }
        catch ClaudeUsageQueryError.timeout { }
        let oversized = try fixture("oversized", body: "sys.stdout.buffer.write(b'A' * 2000000)\n")
        do { _ = try await ClaudeUsageQueryClient.fetch(executable: oversized); fatalError("Expected output bound") }
        catch ClaudeUsageQueryError.oversizedOutput { }
        try FileManager.default.removeItem(at: pidFile)
        let cancelled = Task { try await ClaudeUsageQueryClient.fetch(executable: slow) }
        let launchDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !FileManager.default.fileExists(atPath: pidFile.path) && ProcessInfo.processInfo.systemUptime < launchDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let childPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        cancelled.cancel()
        precondition(kill(childPID, 0) == -1 && errno == ESRCH, "Cancellation must stop the child synchronously, including on app exit")
        do { _ = try await cancelled.value; fatalError("Expected cancellation") } catch is CancellationError { }
        let suite = "QuotAIUsageProbe-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ClaudeCodeUsageStore.enabledDefaultsKey)
        let counter = QueryCounter(), cache = directory.appendingPathComponent("cache.json")
        let store = ClaudeCodeUsageStore(defaults: defaults, cacheURL: cache, migrateBridge: false, query: { await counter.fetch(snapshot) })
        store.start()
        let startupCount = await counter.count
        precondition(startupCount == 0 && store.snapshot == nil)
        let first = Task { await store.userRefresh() }
        try await Task.sleep(for: .milliseconds(20))
        await store.userRefresh()
        await first.value
        let refreshCount = await counter.count
        precondition(refreshCount == 1 && store.snapshot?.fiveHour?.quota.remainingPercent == 85)
        let late = Task { await store.userRefresh() }
        try await Task.sleep(for: .milliseconds(20)); try store.clearReports()
        await late.value
        precondition(store.snapshot == nil && !FileManager.default.fileExists(atPath: cache.path))
        let disabling = Task { await store.userRefresh() }
        try await Task.sleep(for: .milliseconds(20)); try store.disable()
        await disabling.value
        precondition(store.snapshot == nil && !store.isEnabled && !FileManager.default.fileExists(atPath: cache.path))
        try ClaudeUsageQueryCache.write(snapshot, to: cache)
        precondition(store.hasQueryCache)
        try store.clearReports()
        precondition(!store.hasQueryCache)
        print("PASS: actual child stdout, timeout, size limit, synchronous child cancellation, startup without query, coalesced refresh, late-result rejection after clear/disable, clear while disabled")
    }
}
