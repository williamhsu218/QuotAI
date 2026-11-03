import Darwin
import Foundation

/// Runs when Claude Code invokes `QuotAI --claude-statusline` as its status
/// line command. It never starts the app UI, never touches the network and
/// no longer collects any usage data. The user's
/// previous status line, if any, receives the same input and prints as before.
enum ClaudeStatusLineBridge {
    static let argument = "--claude-statusline"

    /// Inputs up to this size are handed to the previous command through a
    /// pipe before `exec`, which cannot block below the pipe buffer size.
    private static let execInputLimit = 8_192

    static func run() -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()

        // Retire an owned legacy hook without breaking an already-open terminal.
        // Missing or unreadable migration state leaves the configuration untouched.
        _ = try? ClaudeStatusLineRetirement.retireIfNeeded()

        // Never recurse if a previous command somehow points back here.
        guard ProcessInfo.processInfo.environment[ClaudeStatusLineRetirement.bridgeEnvironmentKey] == nil,
              let previous = ClaudeStatusLineRetirement.previousCommand() else {
            return 0
        }
        setenv(ClaudeStatusLineRetirement.bridgeEnvironmentKey, "1", 1)

        if input.count <= execInputLimit {
            execPrevious(previous, input: input)
        }
        return runPrevious(previous, input: input)
    }

    /// Replaces this process with the previous status line command so
    /// Claude Code's cancellation signals reach it directly. Returns only if
    /// exec fails.
    private static func execPrevious(_ command: String, input: Data) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return }
        let written = input.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
            return write(descriptors[1], base, buffer.count)
        }
        close(descriptors[1])
        guard written == input.count,
              dup2(descriptors[0], STDIN_FILENO) >= 0 else {
            close(descriptors[0])
            return
        }
        close(descriptors[0])

        let arguments = ["/bin/sh", "-c", command]
        var cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        cArguments.append(nil)
        execv("/bin/sh", &cArguments)
        for pointer in cArguments { free(pointer) }
    }

    private static func runPrevious(_ command: String, input: Data) -> Int32 {
        let process = Process()
        let inputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            try inputPipe.fileHandleForWriting.write(contentsOf: input)
            try inputPipe.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
