import Darwin
import Foundation

/// Isolated subprocess regression probe. Never contacts a real Codex account.
/// Compile with Core/*.swift and the Codex client/locator services, then run
/// with QUOTAI_PROBE_MODE set to silent, eof, unsupported, usage, launchFailure
/// or emptyCredits.
@main
struct ClientFallbackProbe {
    static func main() async throws {
        signal(SIGPIPE, SIG_IGN)
        let mode = ProcessInfo.processInfo.environment["QUOTAI_PROBE_MODE"] ?? "silent"
        precondition(["silent", "eof", "unsupported", "usage", "launchFailure", "emptyCredits"].contains(mode))
        if CommandLine.arguments.contains("app-server") {
            for _ in 0..<5 { _ = readLine() }
            if mode == "launchFailure" { exit(127) }
            let credits = mode == "emptyCredits" ? 0 : 1
            let quota =
                #"{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":18,"windowDurationMins":300,"resetsAt":1784122800}},"rateLimitResetCredits":{"availableCount":\#(credits),"credits":[]}}}"#
            try FileHandle.standardOutput.write(contentsOf: Data((quota + "\n").utf8))
            if mode == "unsupported" {
                try FileHandle.standardOutput.write(
                    contentsOf: Data((#"{"id":4,"error":{"code":-32601,"message":"Method not found"}}"# + "\n").utf8))
            } else if mode == "usage" || mode == "emptyCredits" {
                try FileHandle.standardOutput.write(
                    contentsOf: Data(
                        (#"{"id":4,"result":{"dailyUsageBuckets":[{"startDate":"2026-09-07","tokens":1000}]}}"# + "\n")
                            .utf8))
            }
            if mode != "eof" && mode != "emptyCredits" { try await Task.sleep(for: .seconds(10)) }
            return
        }
        let started = Date()
        if mode == "launchFailure" {
            do {
                _ = try await CodexAppServerClient().fetch(
                    customPath: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path)
                preconditionFailure("Expected an early subprocess exit to fail")
            } catch CodexAppServerClientError.launchFailed {
                precondition(Date().timeIntervalSince(started) < 3)
                print("PASS launchFailure: early exit reported as a startup failure")
                return
            }
        }
        if mode == "emptyCredits" {
            let path = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
            let single = try await CodexAppServerClient().fetch(customPath: path)
            precondition(single.hasCurrentResetCreditData && single.availableResetCount == 0)
            precondition(
                Date().timeIntervalSince(started) < 1.5,
                "An account without previous credits must not wait for a confirmation read")
            let confirmationStarted = Date()
            let confirmed = try await CodexAppServerClient().fetch(customPath: path, confirmsEmptyResetCredits: true)
            precondition(confirmed.availableResetCount == 0)
            precondition(
                Date().timeIntervalSince(confirmationStarted) >= 2,
                "Previously held credits must be confirmed once before they are cleared")
            print("PASS emptyCredits: one read without previous credits, one confirmation otherwise")
            return
        }
        let snapshot = try await CodexAppServerClient().fetch(
            customPath: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path)
        let elapsed = Date().timeIntervalSince(started)
        precondition(snapshot.fiveHour?.remainingPercent == 82)
        precondition(snapshot.hasCurrentTokenUsageData == (mode == "usage"))
        precondition(elapsed < (mode == "silent" ? 7 : 3))
        print("PASS \(mode): valid quota retained in \(String(format: "%.2f", elapsed))s")
    }
}
