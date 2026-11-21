import Darwin
import Foundation

/// Blocking pipe reads and child reaping belong on a Dispatch worker, never
/// Swift's cooperative executor. Each provider owns its queue to avoid one
/// provider's timeout delaying another provider.
enum ProcessIO {
    enum CaptureError: Error {
        case launchFailed
        case timedOut
        case invalidOutput
        case oversizedOutput
        case unsuccessfulExit
    }

    static func run<T: Sendable>(
        on queue: DispatchQueue,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }

    static func capture(
        executable: URL, arguments: [String], environment: [String: String]? = nil,
        timeout: TimeInterval, outputLimit: Int, acceptedExitCodes: [Int32] = [0], on queue: DispatchQueue
    ) async throws -> Data {
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            try await run(on: queue) {
                try control.checkCancellation()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "quotai-usage-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }

                let process = Process()
                let output = Pipe()
                process.executableURL = executable
                process.currentDirectoryURL = directory
                process.arguments = arguments
                if let environment { process.environment = environment }
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try control.launch(process)
                try? output.fileHandleForWriting.close()
                defer {
                    control.stop()
                    try? output.fileHandleForReading.close()
                }
                let data = try readOutput(
                    from: output.fileHandleForReading, process: process, control: control,
                    timeout: timeout, outputLimit: outputLimit)
                guard acceptedExitCodes.contains(process.terminationStatus) else { throw CaptureError.unsuccessfulExit }
                return data
            }
        } onCancel: {
            control.cancel()
        }
    }

    private static func readOutput(
        from output: FileHandle, process: Process, control: ProcessControl,
        timeout: TimeInterval, outputLimit: Int
    ) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try control.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CaptureError.timedOut }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw CaptureError.invalidOutput
            }
            if ready == 0 { continue }
            let count = Darwin.read(descriptor.fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw CaptureError.invalidOutput
            }
            if count == 0 { break }
            guard count <= outputLimit - data.count else { throw CaptureError.oversizedOutput }
            data.append(contentsOf: buffer.prefix(count))
        }
        while process.isRunning {
            try control.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CaptureError.timedOut }
            usleep(10_000)
        }
        try control.checkCancellation()
        return data
    }
}

/// Let cancellation signal only this invocation, then reap it on the I/O worker.
private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func launch(_ child: Process) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            do { try child.run() } catch { throw ProcessIO.CaptureError.launchFailed }
            process = child
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
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
        child?.waitUntilExit()
    }
}
