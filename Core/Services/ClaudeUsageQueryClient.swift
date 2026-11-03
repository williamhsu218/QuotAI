import Darwin
import Foundation

/// Serializes launch and teardown so cancellation (including app shutdown)
/// signals this query's child immediately; the I/O worker reaps it before completion.
private final class ClaudeUsageProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func launch(_ child: Process) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try child.run()
            process = child
        }
    }
    func cancel() {
        lock.withLock {
            cancelled = true
            // No grace-period sleep or wait on the cancelling (often main) thread.
            if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    func checkCancellation() throws {
        try lock.withLock { if cancelled { throw CancellationError() } }
    }
    func stop() {
        let child = lock.withLock { () -> Process? in
            guard let child = process else { return nil }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            process = nil
            return child
        }
        // Only the Dispatch I/O worker calls stop(). Never wait while holding
        // the lock shared with the main-thread cancellation path.
        child?.waitUntilExit()
    }
}

enum ClaudeUsageQueryClient {
    static func fetch(executable: URL? = nil, timeout: TimeInterval = 20) async throws -> ClaudeCodeQuotaSnapshot {
        let data = try await execute(executable: executable, timeout: timeout,
            arguments: ["-p", "/usage", "--output-format", "json", "--no-session-persistence", "--setting-sources", "",
                "--settings", "{\"disableAllHooks\":true,\"promptSuggestionEnabled\":false}",
                "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", ""],
            outputLimit: ClaudeUsageQueryParser.outputLimit)
        return try ClaudeUsageQueryParser.parse(data, at: Date())
    }

    static func fetchSubscription(executable: URL? = nil, timeout: TimeInterval = 5) async throws -> ClaudeCodeSubscriptionPlan? {
        let data = try await execute(executable: executable, timeout: timeout,
            arguments: ["auth", "status", "--json"], outputLimit: ClaudeCodeSubscriptionParser.outputLimit,
            acceptedExitCodes: [0, 1]) // auth status exits 1 when logged out.
        return try ClaudeCodeSubscriptionParser.parse(data)
    }

    private static func execute(executable: URL?, timeout: TimeInterval, arguments: [String],
                                outputLimit: Int, acceptedExitCodes: [Int32] = [0]) async throws -> Data {
        let control = ClaudeUsageProcessControl()
        let queue = DispatchQueue(label: "com.willhsu.QuotAI.claude-io", qos: .utility)
        return try await withTaskCancellationHandler(operation: {
            try await ProcessIO.run(on: queue) {
                try run(executable: executable, timeout: timeout, arguments: arguments,
                        outputLimit: outputLimit, acceptedExitCodes: acceptedExitCodes, control: control)
            }
        }, onCancel: {
            control.cancel()
        })
    }

    private static func run(executable: URL?, timeout: TimeInterval, arguments: [String],
                            outputLimit: Int, acceptedExitCodes: [Int32], control: ClaudeUsageProcessControl) throws -> Data {
        guard let executable = executable ?? ClaudeUsageBinaryLocator.locate() else { throw ClaudeUsageQueryError.cliMissing }
        try control.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotai-usage-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = CodexProcessEnvironment.resolve(targetURL: URL(string: "https://claude.ai")!).environment
        environment["LANG"] = "en_US.UTF-8"; environment["LC_ALL"] = "en_US.UTF-8"
        environment["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] + (environment["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        process.environment = environment
        do { try control.launch(process) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ClaudeUsageQueryError.launchFailed }
        try? output.fileHandleForWriting.close()
        defer {
            control.stop()
            try? output.fileHandleForReading.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data(), eof = false
        while !eof {
            try control.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ClaudeUsageQueryError.timeout }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; throw ClaudeUsageQueryError.invalidOutput }
            if ready > 0 {
                var bytes = [UInt8](repeating: 0, count: 16_384)
                let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                guard count >= 0 else { if errno == EINTR { continue }; throw ClaudeUsageQueryError.invalidOutput }
                if count == 0 { eof = true }
                else {
                    data.append(contentsOf: bytes.prefix(count))
                    guard data.count <= outputLimit else { throw ClaudeUsageQueryError.oversizedOutput }
                }
            }
        }
        while process.isRunning {
            try control.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ClaudeUsageQueryError.timeout }
            usleep(10_000)
        }
        try control.checkCancellation()
        guard acceptedExitCodes.contains(process.terminationStatus) else { throw ClaudeUsageQueryError.commandFailed }
        return data
    }
}
