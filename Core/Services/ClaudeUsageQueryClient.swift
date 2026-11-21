import Foundation

enum ClaudeUsageQueryClient {
    static func fetch(executable: URL? = nil, timeout: TimeInterval = 20) async throws -> ClaudeCodeQuotaSnapshot {
        let data = try await execute(
            executable: executable, timeout: timeout,
            arguments: [
                "-p", "/usage", "--output-format", "json", "--no-session-persistence", "--setting-sources", "",
                "--settings", "{\"disableAllHooks\":true,\"promptSuggestionEnabled\":false}",
                "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", ""
            ],
            outputLimit: ClaudeUsageQueryParser.outputLimit)
        return try ClaudeUsageQueryParser.parse(data, at: Date())
    }

    static func fetchSubscription(
        executable: URL? = nil, timeout: TimeInterval = 5
    ) async throws -> ClaudeCodeSubscriptionPlan? {
        let data = try await execute(
            executable: executable, timeout: timeout,
            arguments: ["auth", "status", "--json"], outputLimit: ClaudeCodeSubscriptionParser.outputLimit,
            acceptedExitCodes: [0, 1])  // auth status exits 1 when logged out.
        return try ClaudeCodeSubscriptionParser.parse(data)
    }

    private static func execute(
        executable: URL?, timeout: TimeInterval, arguments: [String],
        outputLimit: Int, acceptedExitCodes: [Int32] = [0]
    ) async throws -> Data {
        guard let executable = executable ?? ClaudeUsageBinaryLocator.locate() else {
            throw ClaudeUsageQueryError.cliMissing
        }
        var environment = CodexProcessEnvironment.resolve(targetURL: URL(string: "https://claude.ai")!).environment
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["PATH"] =
            (["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        do {
            return try await ProcessIO.capture(
                executable: executable, arguments: arguments, environment: environment,
                timeout: timeout, outputLimit: outputLimit, acceptedExitCodes: acceptedExitCodes,
                on: DispatchQueue(label: "com.willhsu.QuotAI.claude-io", qos: .utility))
        } catch let error as ProcessIO.CaptureError {
            switch error {
            case .launchFailed: throw ClaudeUsageQueryError.launchFailed
            case .timedOut: throw ClaudeUsageQueryError.timeout
            case .invalidOutput: throw ClaudeUsageQueryError.invalidOutput
            case .oversizedOutput: throw ClaudeUsageQueryError.oversizedOutput
            case .unsuccessfulExit: throw ClaudeUsageQueryError.commandFailed
            }
        }
    }
}
