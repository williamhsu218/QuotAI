import Darwin
import Foundation

/// Serializes launch and teardown so cancellation (including app shutdown)
/// finishes this query's child before the store can start another one.
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
        lock.withLock { cancelled = true; stopLocked() }
    }
    func stop() {
        lock.withLock { stopLocked() }
    }
    private func stopLocked() {
        guard let child = process else { return }
        if child.isRunning {
            child.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.3
            while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        // Avoid waitUntilExit pumping the main run loop while cancellation
        // holds this lock; Foundation observes child termination separately.
        while child.isRunning { usleep(1_000) }
        child.waitUntilExit()
        process = nil
    }
}

enum ClaudeUsageQueryClient {
    static func fetch(executable: URL? = nil, timeout: TimeInterval = 20) async throws -> ClaudeCodeQuotaSnapshot {
        let control = ClaudeUsageProcessControl()
        let worker = Task.detached(priority: .utility) { try run(executable: executable, timeout: timeout, control: control) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: {
            worker.cancel()
            control.cancel()
        })
    }

    private static func run(executable: URL?, timeout: TimeInterval, control: ClaudeUsageProcessControl) throws -> ClaudeCodeQuotaSnapshot {
        guard let executable = executable ?? ClaudeUsageBinaryLocator.locate() else { throw ClaudeUsageQueryError.cliMissing }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quotai-usage-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.arguments = ["-p", "/usage", "--output-format", "json", "--no-session-persistence", "--setting-sources", "",
            "--settings", "{\"disableAllHooks\":true,\"promptSuggestionEnabled\":false}",
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", ""]
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
            try Task.checkCancellation()
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
                    guard data.count <= ClaudeUsageQueryParser.outputLimit else { throw ClaudeUsageQueryError.oversizedOutput }
                }
            }
        }
        while process.isRunning {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ClaudeUsageQueryError.timeout }
            usleep(10_000)
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw ClaudeUsageQueryError.commandFailed }
        return try ClaudeUsageQueryParser.parse(data, at: Date())
    }
}
