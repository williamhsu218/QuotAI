import Darwin
import Foundation
import OSLog

enum AntigravityQuotaClientError: LocalizedError {
    case notRunning
    case runtimeUnavailable
    case quotaUnavailable
    case protocolChanged
    case cliUnavailable
    case cliTimedOut
    case cliQueryFailed

    var errorDescription: String? {
        switch self {
        case .notRunning:
            L10n.text(
                "error.antigravity.not_running",
                fallback: "Open Antigravity to read its quota."
            )
        case .runtimeUnavailable:
            L10n.text(
                "error.antigravity.runtime_unavailable",
                fallback: "Antigravity's local quota service is unavailable."
            )
        case .quotaUnavailable:
            L10n.text(
                "error.antigravity.quota_unavailable",
                fallback: "Antigravity quota is temporarily unavailable."
            )
        case .protocolChanged:
            L10n.text(
                "error.antigravity.protocol_changed",
                fallback: "This Antigravity version uses an unsupported quota format."
            )
        case .cliUnavailable:
            L10n.text(
                "error.antigravity.cli_unavailable",
                fallback: "Install or update Antigravity CLI to 1.5.13 or later, then sign in to read quota."
            )
        case .cliTimedOut:
            L10n.text(
                "error.antigravity.cli_timed_out",
                fallback: "Antigravity CLI did not return quota in time. Try again shortly."
            )
        case .cliQueryFailed:
            L10n.text(
                "error.antigravity.cli_query_failed",
                fallback: "Antigravity CLI couldn't read quota. Check that you're signed in and try again."
            )
        }
    }
}

actor AntigravityQuotaClient {
    static let shared = AntigravityQuotaClient()
    private nonisolated static let languageServerPattern =
        #"[/]Antigravity( IDE)?\.app/Contents/Resources/bin/language_server( |$)"#
    private nonisolated static let quotaPath =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private nonisolated static let userStatusPath =
        "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.willhsu.QuotAI",
        category: "AntigravityQuota"
    )

    struct Runtime: Sendable, Hashable {
        let processID: Int32
        let host: String
        let port: Int
        let scheme: String
        let csrfToken: String
    }

    enum Discovery: Sendable {
        case localService([Runtime])
        case cli
    }

    private nonisolated static let discoveryQueue = DispatchQueue(
        label: "com.willhsu.QuotAI.antigravity-discovery", qos: .utility)
    private let discover: @Sendable () async throws -> Discovery
    private let isAlive: @Sendable (Int32) -> Bool
    private let rpc: @Sendable (Runtime, String, String) async throws -> Data
    private let cli: @Sendable () async throws -> AntigravityQuotaSnapshot
    private var cachedRuntime: Runtime?

    init(
        discover: @escaping @Sendable () async throws -> Discovery = {
            try await ProcessIO.run(on: AntigravityQuotaClient.discoveryQueue) {
                try AntigravityQuotaClient.discoverRuntimes()
            }
        },
        isAlive: @escaping @Sendable (Int32) -> Bool = { kill($0, 0) == 0 },
        rpc: (@Sendable (Runtime, String, String) async throws -> Data)? = nil,
        cli: @escaping @Sendable () async throws -> AntigravityQuotaSnapshot = { try await AntigravityCLI.fetch() }
    ) {
        self.discover = discover
        self.isAlive = isAlive
        self.cli = cli
        if let rpc {
            self.rpc = rpc
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 15
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            let session = URLSession(
                configuration: configuration, delegate: LoopbackSessionDelegate(), delegateQueue: nil)
            self.rpc = { runtime, path, body in
                try await Self.requestRPC(session: session, path: path, body: body, runtime: runtime)
            }
        }
    }

    func fetch() async throws -> AntigravityQuotaSnapshot {
        try Task.checkCancellation()
        if let runtime = cachedRuntime, isAlive(runtime.processID) {
            do { return try await read(runtime) } catch is CancellationError { throw CancellationError() } catch {
                try Task.checkCancellation()
                cachedRuntime = nil
            }
        } else {
            cachedRuntime = nil
        }

        let discovery = try await discover()
        try Task.checkCancellation()
        guard case .localService(let runtimes) = discovery else {
            let snapshot = try await cli()
            try Task.checkCancellation()
            Self.logger.info(
                "Antigravity CLI quota refresh succeeded; groupCount=\(snapshot.groups.count, privacy: .public)")
            return snapshot
        }
        var receivedUnrecognizedResponse = false
        for runtime in runtimes {
            try Task.checkCancellation()
            do {
                let snapshot = try await read(runtime)
                cachedRuntime = runtime  // Memory only, including the selected scheme.
                Self.logger.info(
                    "Antigravity quota refresh succeeded; groupCount=\(snapshot.groups.count, privacy: .public)")
                return snapshot
            } catch is CancellationError { throw CancellationError() } catch is AntigravityQuotaParserError {
                receivedUnrecognizedResponse = true
            } catch AntigravityQuotaClientError.protocolChanged { receivedUnrecognizedResponse = true } catch {
                try Task.checkCancellation()
                continue
            }
        }
        if receivedUnrecognizedResponse { throw AntigravityQuotaClientError.protocolChanged }
        throw runtimes.isEmpty
            ? AntigravityQuotaClientError.runtimeUnavailable : AntigravityQuotaClientError.quotaUnavailable
    }

    private func read(_ runtime: Runtime) async throws -> AntigravityQuotaSnapshot {
        let data = try await rpc(runtime, Self.quotaPath, #"{"forceRefresh":true}"#)
        let status = try? await rpc(runtime, Self.userStatusPath, "{}")
        try Task.checkCancellation()
        return try AntigravityQuotaParser.parse(data: data, userStatusData: status)
    }

    private nonisolated static func discoverRuntimes() throws -> Discovery {
        let processIDs = try languageServerProcessIDs()
        guard !processIDs.isEmpty else { throw AntigravityQuotaClientError.notRunning }
        var runtimes: [Runtime] = []
        var usesHostBridge = false
        for processID in processIDs {
            guard let commandLine = try? commandLine(processID: processID) else { continue }
            guard
                let token = argumentValue(named: "--csrf_token", in: commandLine)
                    ?? argumentValue(named: "--csrf-token", in: commandLine),
                !token.isEmpty, !token.contains(where: \.isNewline)
            else {
                usesHostBridge =
                    usesHostBridge
                    || commandLine.split(whereSeparator: \.isWhitespace).contains {
                        $0 == "--read_host_bridge_token_from_stdin" || $0 == "--read_host_bridge_token_from_stdin=true"
                    }
                continue
            }
            guard let endpoints = try? listeningEndpoints(processID: processID) else { continue }
            for endpoint in endpoints {
                for scheme in ["http", "https"] {
                    runtimes.append(
                        Runtime(
                            processID: processID, host: endpoint.host, port: endpoint.port, scheme: scheme,
                            csrfToken: token))
                }
            }
        }
        return runtimes.isEmpty && usesHostBridge ? .cli : .localService(runtimes)
    }

    private nonisolated static func languageServerProcessIDs() throws -> [Int32] {
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-f", languageServerPattern]
        )
        guard result.status == 0 else { return [] }
        return String(decoding: result.output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private nonisolated static func commandLine(processID: Int32) throws -> String {
        let result = try run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-ww", "-p", String(processID), "-o", "command="]
        )
        guard result.status == 0 else {
            throw AntigravityQuotaClientError.runtimeUnavailable
        }
        return String(decoding: result.output, as: UTF8.self)
    }

    private nonisolated static func argumentValue(
        named name: String,
        in commandLine: String
    ) -> String? {
        if let range = commandLine.range(of: "\(name)=") {
            let value = commandLine[range.upperBound...].prefix { !$0.isWhitespace }
            return value.isEmpty ? nil : String(value)
        }

        let arguments = commandLine.split(whereSeparator: \.isWhitespace)
        guard let index = arguments.firstIndex(of: Substring(name)),
            arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return String(arguments[index + 1])
    }

    private nonisolated static func listeningEndpoints(
        processID: Int32
    ) throws -> [LoopbackEndpoint] {
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: [
                "-nP", "-a", "-p", String(processID),
                "-iTCP", "-sTCP:LISTEN", "-FnP"
            ]
        )
        guard result.status == 0 else { return [] }

        var endpoints: [LoopbackEndpoint] = []
        for line in String(decoding: result.output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        {
            if line.hasPrefix("n127.0.0.1:"),
                let port = Int(line.dropFirst("n127.0.0.1:".count))
            {
                endpoints.append(LoopbackEndpoint(host: "127.0.0.1", port: port))
            } else if line.hasPrefix("n[::1]:"),
                let port = Int(line.dropFirst("n[::1]:".count))
            {
                endpoints.append(LoopbackEndpoint(host: "[::1]", port: port))
            }
        }
        return Array(Set(endpoints)).sorted { $0.port < $1.port }
    }

    private nonisolated static func requestRPC(
        session: URLSession, path: String, body: String, runtime: Runtime
    ) async throws -> Data {
        guard ["127.0.0.1", "[::1]"].contains(runtime.host),
            (1...65535).contains(runtime.port), ["http", "https"].contains(runtime.scheme),
            let url = URL(string: "\(runtime.scheme)://\(runtime.host):\(runtime.port)\(path)")
        else {
            throw AntigravityQuotaClientError.runtimeUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(runtime.csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (bytes, response) = try await session.bytes(
            for: request, delegate: session.delegate as? LoopbackSessionDelegate)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw AntigravityQuotaClientError.quotaUnavailable
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw AntigravityQuotaClientError.protocolChanged }
            data.append(byte)
        }
        guard !data.isEmpty else { throw AntigravityQuotaClientError.quotaUnavailable }
        return data
    }

    private nonisolated static func run(
        executable: URL,
        arguments: [String],
        standardInput: Data? = nil
    ) throws -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = standardInput == nil ? nil : Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            if let standardInput, let inputPipe {
                try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
                try inputPipe.fileHandleForWriting.close()
            }
        } catch {
            if process.isRunning { process.terminate() }
            throw AntigravityQuotaClientError.runtimeUnavailable
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: output)
    }
}

enum AntigravityCLI {
    private static let queue = DispatchQueue(
        label: "com.willhsu.QuotAI.antigravity-cli", qos: .utility, attributes: .concurrent)
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.willhsu.QuotAI", category: "AntigravityCLI")

    static func fetch(executable: URL? = nil, usageTimeout: TimeInterval = 32) async throws -> AntigravityQuotaSnapshot
    {
        guard let executable = executable ?? locate() else { throw AntigravityQuotaClientError.cliUnavailable }
        do {
            let version = try await ProcessIO.capture(
                executable: executable, arguments: ["--version"], timeout: 4, outputLimit: 1024, on: queue)
            guard supportsHeadlessUsage(version) else { throw AntigravityQuotaClientError.cliUnavailable }

            // The two read-only commands use separate working directories and can run together.
            async let modelList = try? ProcessIO.capture(
                executable: executable, arguments: ["models"], timeout: 12, outputLimit: 128 * 1024, on: queue)
            let quota: Data
            do {
                quota = try await ProcessIO.capture(
                    executable: executable,
                    arguments: [
                        "--settings", #"{"disableSlashCommands":false}"#, "--print-timeout", "28s",
                        "--log-file", "agy.log", "--output-format", "json", "-p", "/usage"
                    ], timeout: usageTimeout, outputLimit: 1_048_576, on: queue)
            } catch ProcessIO.CaptureError.timedOut {
                try Task.checkCancellation()
                throw AntigravityQuotaClientError.cliTimedOut
            }
            let models = await modelList
            try Task.checkCancellation()
            return try AntigravityQuotaParser.parseCLIReport(quota, modelList: models)
        } catch ProcessIO.CaptureError.oversizedOutput {
            throw AntigravityQuotaClientError.protocolChanged
        } catch is ProcessIO.CaptureError {
            try Task.checkCancellation()
            throw AntigravityQuotaClientError.cliQueryFailed
        } catch is AntigravityQuotaParserError {
            throw AntigravityQuotaClientError.protocolChanged
        }
    }

    /// Reads the authenticated account's subscription tier from Antigravity CLI's
    /// documented `statusLine` JSON payload using an ephemeral `--settings` override
    /// in an isolated temporary directory. Never modifies user settings or sends a prompt.
    static func fetchSubscriptionPlan(
        executable: URL? = nil, timeout: TimeInterval = 20
    ) async throws -> SubscriptionPlan? {
        guard let executable = executable ?? locate() else { throw AntigravityQuotaClientError.cliUnavailable }
        let version: Data
        do {
            version = try await ProcessIO.capture(
                executable: executable, arguments: ["--version"], timeout: 4, outputLimit: 1024, on: queue)
        } catch is ProcessIO.CaptureError {
            try Task.checkCancellation()
            throw AntigravityQuotaClientError.cliQueryFailed
        }
        guard supportsHeadlessUsage(version) else { throw AntigravityQuotaClientError.cliUnavailable }

        let control = PlanProbeControl()
        return try await withTaskCancellationHandler {
            try await ProcessIO.run(on: queue) {
                try control.checkCancellation()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "quotai-agy-plan-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }

                let tierFile = directory.appendingPathComponent("tier")
                let idleFile = directory.appendingPathComponent("idle")
                let scriptFile = directory.appendingPathComponent("statusline.sh")
                // The callback also receives account and workspace details. Only the tier may leave its stdin.
                let script = #"""
                    #!/bin/sh
                    umask 077
                    directory=${0%/*}
                    payload=$(/usr/bin/head -c 65537) || exit 1
                    [ "${#payload}" -le 65536 ] || exit 1
                    extract() {
                        printf '%s' "$payload" | /usr/bin/plutil -extract "$1" raw -expect string -o - -- - 2>/dev/null
                    }
                    if tier=$(extract plan_tier) && [ -n "$tier" ]; then
                        temporary=$(/usr/bin/mktemp "$directory/tier.XXXXXX") || exit 1
                        printf '%s' "$tier" > "$temporary" && /bin/mv -f "$temporary" "$directory/tier"
                    elif [ "$(extract agent_state)" = idle ]; then
                        /usr/bin/touch "$directory/idle"
                    fi
                    printf 'ok\n'
                    """#
                try Data(script.utf8).write(to: scriptFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptFile.path)

                let settingsObject: [String: Any] = [
                    "statusLine": [
                        "type": "command",
                        "command": "'" + scriptFile.path.replacingOccurrences(of: "'", with: "'\\''") + "'",
                        "enabled": true
                    ]
                ]
                let settingsData = try JSONSerialization.data(withJSONObject: settingsObject)
                let settingsJSON = String(decoding: settingsData, as: UTF8.self)

                var masterFD: Int32 = -1
                var slaveFD: Int32 = -1
                var windowSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
                guard Darwin.openpty(&masterFD, &slaveFD, nil, nil, &windowSize) == 0 else {
                    logger.error("Could not allocate an Antigravity status line terminal")
                    throw AntigravityQuotaClientError.cliQueryFailed
                }
                defer { Darwin.close(masterFD) }
                _ = fcntl(masterFD, F_SETFD, FD_CLOEXEC)
                _ = fcntl(slaveFD, F_SETFD, FD_CLOEXEC)

                let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
                let process = Process()
                process.executableURL = executable
                process.currentDirectoryURL = directory
                process.arguments = ["--settings", settingsJSON, "--log-file", "agy.log"]
                var environment = ProcessInfo.processInfo.environment
                environment["TERM"] = "xterm-256color"
                process.environment = environment
                process.standardInput = slaveHandle
                process.standardOutput = slaveHandle
                process.standardError = slaveHandle

                do {
                    try control.launch(process)
                } catch {
                    Darwin.close(slaveFD)
                    if !(error is CancellationError) { logger.error("Could not launch the Antigravity status line") }
                    throw error
                }
                Darwin.close(slaveFD)
                defer { control.stop() }

                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                var buffer = [UInt8](repeating: 0, count: 8_192)

                while ProcessInfo.processInfo.systemUptime < deadline {
                    try control.checkCancellation()

                    var descriptor = pollfd(fd: masterFD, events: Int16(POLLIN | POLLHUP), revents: 0)
                    let ready = Darwin.poll(&descriptor, 1, 150)
                    if ready < 0 && errno != EINTR {
                        logger.error("Could not read the Antigravity status line terminal")
                        throw AntigravityQuotaClientError.cliQueryFailed
                    }
                    if ready > 0 && (descriptor.revents & Int16(POLLIN)) != 0 {
                        _ = Darwin.read(masterFD, &buffer, buffer.count)
                    }

                    let isRunning = process.isRunning
                    if let plan = readPlanTier(tierFile) { return plan }
                    if !isRunning {
                        try control.checkCancellation()
                        let exitStatus = process.terminationStatus
                        if exitStatus == 0 && FileManager.default.fileExists(atPath: idleFile.path) {
                            return nil
                        }
                        logger.error("Antigravity status line exited with status \(exitStatus, privacy: .public)")
                        throw AntigravityQuotaClientError.cliQueryFailed
                    }
                }
                try control.checkCancellation()
                // An idle event without a tier can arrive before account metadata has loaded.
                // Only treat the field as absent after allowing the full callback window.
                if let plan = readPlanTier(tierFile) { return plan }
                if FileManager.default.fileExists(atPath: idleFile.path) { return nil }
                logger.error("Antigravity status line timed out before account metadata arrived")
                throw AntigravityQuotaClientError.cliQueryFailed
            }
        } onCancel: {
            control.cancel()
        }
    }

    private static func readPlanTier(_ url: URL) -> SubscriptionPlan? {
        guard let data = try? Data(contentsOf: url), data.count <= 128,
            let tier = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            tier.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return AntigravityQuotaParser.cliSubscriptionPlan(tier)
    }

    private static func supportsHeadlessUsage(_ data: Data) -> Bool {
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        return parts.count == 3 && numbers.count == 3 && numbers.allSatisfy { $0 >= 0 }
            && !numbers.lexicographicallyPrecedes([1, 5, 13])
    }

    private static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates =
            [home.appendingPathComponent(".local/bin/agy").path, "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            + path.split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/agy" }
        return candidates.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }.first {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType) == .typeRegular
                && FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}

private struct LoopbackEndpoint: Hashable, Sendable {
    let host: String
    let port: Int
}

private struct CommandResult: Sendable {
    let status: Int32
    let output: Data
}

private final class PlanProbeControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func launch(_ child: Process) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            do { try child.run() } catch { throw AntigravityQuotaClientError.cliQueryFailed }
            process = child
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { kill(process.processIdentifier, SIGTERM) }
        }
    }

    func checkCancellation() throws {
        try lock.withLock { if cancelled { throw CancellationError() } }
    }

    func stop() {
        let child = lock.withLock { () -> Process? in
            guard let child = process else { return nil }
            process = nil
            return child
        }
        guard let child else { return }
        if child.isRunning {
            kill(child.processIdentifier, SIGTERM)
            let graceDeadline = ProcessInfo.processInfo.systemUptime + 0.5
            while child.isRunning && ProcessInfo.processInfo.systemUptime < graceDeadline {
                usleep(20_000)
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
    }
}

/// Antigravity's existing local TLS service uses a self-signed certificate.
/// This exception cannot follow a redirect or authenticate any remote host.
private final class LoopbackSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            ["127.0.0.1", "::1", "[::1]"].contains(space.host), let trust = space.serverTrust
        {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
