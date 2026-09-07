import Darwin
import Foundation
import OSLog

enum CodexAppServerClientError: LocalizedError {
    case launchFailed
    case invalidOutput
    case protocolMismatch(String)
    case networkUnavailable(String)
    case updateRequired
    case chatGPTLoginRequired

    var errorDescription: String? {
        switch self {
        case .launchFailed:
            L10n.text(
                "error.client.launch_failed",
                fallback: "Codex App Server could not start. Confirm that Codex is signed in and working."
            )
        case .invalidOutput:
            L10n.text(
                "error.client.invalid_output",
                fallback: "Codex returned unrecognized quota data."
            )
        case let .protocolMismatch(summary):
            L10n.format(
                "error.client.protocol_format",
                fallback: "The Codex protocol response is incompatible (%@).",
                summary
            )
        case let .networkUnavailable(summary):
            L10n.format(
                "error.client.network_unavailable",
                fallback: "Codex could not connect to ChatGPT. Check this Mac’s network, proxy, or TLS certificate settings (%@).",
                summary
            )
        case .updateRequired:
            L10n.text(
                "error.client.update_required",
                fallback: "This Mac’s Codex version cannot provide quota data. Update ChatGPT or Codex CLI, then try again."
            )
        case .chatGPTLoginRequired:
            L10n.text(
                "error.client.chatgpt_login_required",
                fallback: "Quota data requires a ChatGPT Codex login. Sign in with ChatGPT instead of an API key, then try again."
            )
        }
    }
}

actor CodexAppServerClient {
    private nonisolated static let resetCreditConfirmationDelay: TimeInterval = 2

    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.willhsu.QuotAI",
        category: "CodexProcess"
    )

    func fetch(customPath: String?) async throws -> UsageSnapshot {
        try await Task.detached(priority: .utility) {
            try Self.fetchSynchronously(customPath: customPath)
        }.value
    }

    private nonisolated static func fetchSynchronously(customPath: String?) throws -> UsageSnapshot {
        let executables = try CodexBinaryLocator.candidates(customPath: customPath)
        var failures: [CodexAppServerClientError] = []

        for executable in executables {
            do {
                let snapshot = try fetchSynchronously(executable: executable)
                guard snapshot.hasCurrentResetCreditData,
                      snapshot.availableResetCount == 0,
                      snapshot.resetCredits.isEmpty else {
                    return snapshot
                }

                logger.info(
                    "Reset credits were empty in the initial response; confirming once"
                )
                Thread.sleep(forTimeInterval: resetCreditConfirmationDelay)
                do {
                    let confirmed = try fetchSynchronously(executable: executable)
                    logger.info(
                        "Reset credit confirmation completed; resetCount=\(confirmed.availableResetCount, privacy: .public), current=\(confirmed.hasCurrentResetCreditData, privacy: .public)"
                    )
                    return confirmed.hasCurrentResetCreditData ? confirmed.preservingResetCredits(from: snapshot) : snapshot
                } catch {
                    logger.info(
                        "Reset credit confirmation failed; retaining the initial quota snapshot"
                    )
                    return snapshot
                }
            } catch let error as CodexAppServerClientError {
                failures.append(error)
            } catch {
                failures.append(.protocolMismatch(error.localizedDescription))
            }
        }

        if failures.contains(where: { if case .chatGPTLoginRequired = $0 { true } else { false } }) {
            throw CodexAppServerClientError.chatGPTLoginRequired
        }
        if failures.contains(where: { if case .updateRequired = $0 { true } else { false } }) {
            throw CodexAppServerClientError.updateRequired
        }
        throw failures.last ?? CodexAppServerClientError.launchFailed
    }

    private nonisolated static func fetchSynchronously(executable: URL) throws -> UsageSnapshot {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        let processEnvironment = CodexProcessEnvironment.resolve()
        process.environment = processEnvironment.environment
        logger.info(
            "Launching Codex App Server; proxySource=\(processEnvironment.proxySource.rawValue, privacy: .public), customCA=\(processEnvironment.hasCustomCertificate, privacy: .public)"
        )

        let clientVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.1.1"
        let messages: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "quotai",
                        "title": "QuotAI",
                        "version": clientVersion
                    ],
                    "capabilities": ["experimentalApi": true]
                ]
            ],
            ["method": "initialized", "params": [:]],
            [
                "method": "account/read",
                "id": 2,
                "params": ["refreshToken": false]
            ],
            ["method": "account/rateLimits/read", "id": 3, "params": NSNull()],
            ["method": "account/usage/read", "id": 4, "params": NSNull()]
        ]

        let requestData = try messages.reduce(into: Data()) { buffer, message in
            buffer.append(try JSONSerialization.data(withJSONObject: message))
            buffer.append(0x0A)
        }

        do {
            try process.run()
            try inputPipe.fileHandleForWriting.write(contentsOf: requestData)
        } catch {
            if process.isRunning { process.terminate() }
            throw CodexAppServerClientError.launchFailed
        }

        let reader = outputPipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(15)
        var buffer = Data()
        var firstRateLimitFoundTime: Date? = nil
        let usageGracePeriod: TimeInterval = 4.5

        while Date() < deadline {
            let wakeDeadline = min(deadline, firstRateLimitFoundTime?.addingTimeInterval(usageGracePeriod) ?? deadline)
            let remainingMilliseconds = max(1, Int32(wakeDeadline.timeIntervalSinceNow * 1_000))
            var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&descriptor, 1, remainingMilliseconds)
            if pollResult < 0 {
                if errno == EINTR { continue }
                break
            }

            var streamEnded = pollResult > 0 && descriptor.revents & Int16(POLLIN) == 0
            if descriptor.revents & Int16(POLLIN) != 0 {
                var bytes = [UInt8](repeating: 0, count: 65_536)
                let byteCount = Darwin.read(reader.fileDescriptor, &bytes, bytes.count)
                if byteCount > 0 {
                    buffer.append(contentsOf: bytes.prefix(Int(byteCount)))
                } else {
                    streamEnded = true
                }
            }
            guard let text = String(data: buffer, encoding: .utf8) else { continue }

            let hasRateLimits = jsonLinesContainResponse(for: 3, in: text)
            let hasUsage = jsonLinesContainResponse(for: 4, in: text)

            if hasRateLimits && firstRateLimitFoundTime == nil {
                firstRateLimitFoundTime = Date()
            }

            let usageTimedOut = hasRateLimits && (firstRateLimitFoundTime.map { Date().timeIntervalSince($0) >= usageGracePeriod } ?? false)
            let shouldAttemptParse = hasRateLimits && (hasUsage || usageTimedOut || streamEnded || Date() >= deadline)

            guard shouldAttemptParse else {
                if streamEnded || Date() >= deadline { break }
                continue
            }

            do {
                let snapshot = try CodexRateLimitParser.parse(
                    jsonLines: text,
                    requestID: 3,
                    usageRequestID: 4
                )
                try? inputPipe.fileHandleForWriting.close()
                stop(process)
                if hasUsage {
                    logger.info("Parsed Codex snapshot; optional usage response received (\(snapshot.dailyUsageBuckets.count, privacy: .public) buckets)")
                } else if usageTimedOut {
                    logger.info("Codex token usage response timed out after grace period; parsed rate limits only")
                }
                return snapshot
            } catch CodexRateLimitParserError.missingResponse {
                continue
            } catch CodexRateLimitParserError.serverError(let code, let message) {
                let authMode = CodexAccountParser.authMode(jsonLines: text)
                try? inputPipe.fileHandleForWriting.close()
                stop(process)
                throw classifiedServerError(
                    code: code,
                    message: message,
                    authMode: authMode
                )
            } catch CodexRateLimitParserError.missingRateLimits {
                let authMode = CodexAccountParser.authMode(jsonLines: text)
                try? inputPipe.fileHandleForWriting.close()
                stop(process)
                if authMode == .apiKey || authMode == .signedOut {
                    throw CodexAppServerClientError.chatGPTLoginRequired
                }
                throw CodexAppServerClientError.invalidOutput
            }
        }

        try? inputPipe.fileHandleForWriting.close()
        stop(process)

        let text = String(data: buffer, encoding: .utf8) ?? ""
        let summary = safeSummary(for: text)
        throw CodexAppServerClientError.protocolMismatch(
            summary.isEmpty
                ? L10n.text(
                    "error.client.timeout",
                    fallback: "No quota response within 15 seconds"
                )
                : summary
        )
    }

    private nonisolated static func classifiedServerError(
        code: Int?,
        message: String,
        authMode: CodexAuthMode
    ) -> CodexAppServerClientError {
        let normalized = message.lowercased()
        if code == -32_601
            || normalized.contains("method not found")
            || normalized.contains("unknown method")
            || normalized.contains("experimentalapi capability") {
            return .updateRequired
        }

        if authMode == .apiKey
            || authMode == .signedOut
            || normalized.contains("not logged")
            || normalized.contains("login required")
            || normalized.contains("requires chatgpt")
            || normalized.contains("not authenticated")
            || normalized.contains("authentication required") {
            return .chatGPTLoginRequired
        }

        if normalized.contains("failed to fetch codex rate limits")
            || normalized.contains("error sending request for url")
            || normalized.contains("dns error")
            || normalized.contains("certificate")
            || normalized.contains("tls")
            || normalized.contains("proxy error") {
            let safeMessage = message
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(180)
            let summary = code.map { "\($0): \(safeMessage)" } ?? String(safeMessage)
            return .networkUnavailable(summary)
        }

        let safeMessage = message
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(180)
        let summary = code.map { "\($0): \(safeMessage)" } ?? String(safeMessage)
        return .protocolMismatch(summary)
    }

    private nonisolated static func stop(_ process: Process) {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }
        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }

    private nonisolated static func safeSummary(for text: String) -> String {
        text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let id = object["id"].map { String(describing: $0) } ?? "notification"
            let keys = object.keys.sorted().joined(separator: ",")
            return "id=\(id) keys=\(keys)"
        }
        .joined(separator: "; ")
    }

    private nonisolated static func jsonLinesContainResponse(for requestID: Int, in text: String) -> Bool {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? Int else {
                continue
            }
            if id == requestID {
                return true
            }
        }
        return false
    }
}
