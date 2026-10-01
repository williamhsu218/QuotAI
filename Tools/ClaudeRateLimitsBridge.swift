import Darwin
import Foundation

/// Standalone helper: no AppKit, account credentials, CLI launch or network.
@main
enum ClaudeRateLimitsBridge {
    private static let execInputLimit = 8_192
    private static let passthroughLimit = 64 * 1_048_576

    static func main() { exit(run()) }

    static func run() -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        guard environment[ClaudeCodeStatusLineConfiguration.bridgeEnvironmentKey] == nil else { return 0 }
        let stateURL = environment["QUOTAI_CLAUDE_V2_STATE"].map { URL(fileURLWithPath: $0) } ?? ClaudeCodeStatusLineConfiguration.stateURL
        let reportsURL = environment["QUOTAI_CLAUDE_V2_REPORTS"].map { URL(fileURLWithPath: $0) } ?? ClaudeCodeReportRepository.reportsURL
        guard let state = try? ClaudeCodeStatusLineConfiguration.readState(stateURL: stateURL) else { return 0 }
        let previous = ClaudeCodeStatusLineConfiguration.previousCommand(stateURL: stateURL)
        // An unlinked spool keeps large passthroughs off the heap and leaves no
        // transcript, file path or status-line JSON on disk after the process.
        var template = Array((NSTemporaryDirectory() + "quotai-statusline-XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { return previous == nil ? 0 : 1 }
        template.withUnsafeBufferPointer { if let base = $0.baseAddress { unlink(base) } }
        defer { close(fd) }
        _ = fchmod(fd, 0o600)
        let spool = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var candidate = Data()
        var total = 0
        do {
            while let chunk = try FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty {
                total += chunk.count
                guard total <= passthroughLimit else { return previous == nil ? 0 : 1 }
                if total <= ClaudeCodeRateLimitParser.inputLimit { candidate.append(chunk) }
                else { candidate.removeAll(keepingCapacity: false) }
                try spool.write(contentsOf: chunk)
            }
            try spool.seek(toOffset: 0)
        } catch { return previous == nil ? 0 : 1 }
        if total <= ClaudeCodeRateLimitParser.inputLimit, state.enabled,
           ClaudeCodeStatusLineConfiguration.check(settingsURL: URL(fileURLWithPath: state.settingsPath), stateURL: stateURL) == .connected {
            // Recording and locking failures never affect the prior command.
            if (try? ClaudeCodeReportRepository.record(input: candidate, state: state, reportsURL: reportsURL)) == true {
                DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.willhsu.QuotAI.claudeCodeUsageSnapshotDidChange"), object: nil, userInfo: nil, deliverImmediately: true)
            }
        }
        guard let previous else { return 0 }
        setenv(ClaudeCodeStatusLineConfiguration.bridgeEnvironmentKey, "1", 1)
        if total <= execInputLimit { execPrevious(previous, input: candidate) }
        return runPrevious(previous, input: spool)
    }

    private static func execPrevious(_ command: String, input: Data) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return }
        let written = input.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
            return write(descriptors[1], base, buffer.count)
        }
        close(descriptors[1])
        guard written == input.count, dup2(descriptors[0], STDIN_FILENO) >= 0 else { close(descriptors[0]); return }
        close(descriptors[0])
        let arguments = ["/bin/sh", "-c", command]
        var pointers = arguments.map { strdup($0) }
        pointers.append(nil)
        execv("/bin/sh", &pointers)
        for pointer in pointers { free(pointer) }
    }

    private static func runPrevious(_ command: String, input: FileHandle) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = input
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do { try process.run() }
        catch { return 1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
