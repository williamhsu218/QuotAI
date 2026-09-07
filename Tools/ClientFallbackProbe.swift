import Foundation

/// Isolated subprocess regression probe. Never contacts a real Codex account.
/// Compile with Core/*.swift and the Codex client/locator services, then run
/// with QUOTAI_PROBE_MODE set to silent, eof, unsupported, or usage.
@main
struct ClientFallbackProbe {
    static func main() async throws {
        let mode = ProcessInfo.processInfo.environment["QUOTAI_PROBE_MODE"] ?? "silent"
        precondition(["silent", "eof", "unsupported", "usage"].contains(mode))
        if CommandLine.arguments.contains("app-server") {
            for _ in 0..<5 { _ = readLine() }
            let quota = #"{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":18,"windowDurationMins":300,"resetsAt":1784122800}},"rateLimitResetCredits":{"availableCount":1,"credits":[]}}}"#
            try FileHandle.standardOutput.write(contentsOf: Data((quota + "\n").utf8))
            if mode == "unsupported" {
                try FileHandle.standardOutput.write(contentsOf: Data((#"{"id":4,"error":{"code":-32601,"message":"Method not found"}}"# + "\n").utf8))
            } else if mode == "usage" {
                try FileHandle.standardOutput.write(contentsOf: Data((#"{"id":4,"result":{"dailyUsageBuckets":[{"startDate":"2026-09-07","tokens":1000}]}}"# + "\n").utf8))
            }
            if mode != "eof" { try await Task.sleep(for: .seconds(10)) }
            return
        }
        let started = Date()
        let snapshot = try await CodexAppServerClient().fetch(customPath: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path)
        let elapsed = Date().timeIntervalSince(started)
        precondition(snapshot.fiveHour?.remainingPercent == 82)
        precondition(snapshot.hasCurrentTokenUsageData == (mode == "usage"))
        precondition(elapsed < (mode == "silent" ? 7 : 3))
        print("PASS \(mode): valid quota retained in \(String(format: "%.2f", elapsed))s")
    }
}
