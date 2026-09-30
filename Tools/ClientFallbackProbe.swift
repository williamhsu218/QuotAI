import Darwin
import Foundation

/// Isolated subprocess regression probe. Never contacts a real Codex account.
/// Compile with Core/*.swift and the Codex client/locator services, then run
/// with QUOTAI_PROBE_MODE set to silent, eof, unsupported, usage, or launchFailure.
@main
struct ClientFallbackProbe {
    static func main() async throws {
        signal(SIGPIPE, SIG_IGN)
        let mode = ProcessInfo.processInfo.environment["QUOTAI_PROBE_MODE"] ?? "silent"
        precondition(["silent", "eof", "unsupported", "usage", "launchFailure"].contains(mode))
        if CommandLine.arguments.contains("app-server") {
            for _ in 0..<5 { _ = readLine() }
            if mode == "launchFailure" { exit(127) }
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
        if mode == "launchFailure" {
            do {
                _ = try await CodexAppServerClient().fetch(customPath: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path)
                preconditionFailure("Expected an early subprocess exit to fail")
            } catch CodexAppServerClientError.launchFailed {
                precondition(Date().timeIntervalSince(started) < 3)
                print("PASS launchFailure: early exit reported as a startup failure")
                return
            }
        }
        let snapshot = try await CodexAppServerClient().fetch(customPath: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path)
        let elapsed = Date().timeIntervalSince(started)
        precondition(snapshot.fiveHour?.remainingPercent == 82)
        precondition(snapshot.hasCurrentTokenUsageData == (mode == "usage"))
        precondition(elapsed < (mode == "silent" ? 7 : 3))
        print("PASS \(mode): valid quota retained in \(String(format: "%.2f", elapsed))s")
    }
}
