import Darwin
import Foundation
import OSLog

enum AntigravityQuotaClientError: LocalizedError {
    case notRunning
    case runtimeUnavailable
    case quotaUnavailable
    case protocolChanged

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

    private nonisolated static let discoveryQueue = DispatchQueue(label: "com.willhsu.QuotAI.antigravity-discovery", qos: .utility)
    private let discover: @Sendable () async throws -> [Runtime]
    private let isAlive: @Sendable (Int32) -> Bool
    private let rpc: @Sendable (Runtime, String, String) async throws -> Data
    private var cachedRuntime: Runtime?

    init(
        discover: @escaping @Sendable () async throws -> [Runtime] = {
            try await ProcessIO.run(on: AntigravityQuotaClient.discoveryQueue) {
                try AntigravityQuotaClient.discoverRuntimes()
            }
        },
        isAlive: @escaping @Sendable (Int32) -> Bool = { kill($0, 0) == 0 },
        rpc: (@Sendable (Runtime, String, String) async throws -> Data)? = nil
    ) {
        self.discover = discover
        self.isAlive = isAlive
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
            let session = URLSession(configuration: configuration, delegate: LoopbackSessionDelegate(), delegateQueue: nil)
            self.rpc = { runtime, path, body in
                try await Self.requestRPC(session: session, path: path, body: body, runtime: runtime)
            }
        }
    }

    func fetch() async throws -> AntigravityQuotaSnapshot {
        try Task.checkCancellation()
        if let runtime = cachedRuntime, isAlive(runtime.processID) {
            do { return try await read(runtime) }
            catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); cachedRuntime = nil }
        } else {
            cachedRuntime = nil
        }

        let runtimes = try await discover()
        var receivedUnrecognizedResponse = false
        for runtime in runtimes {
            try Task.checkCancellation()
            do {
                let snapshot = try await read(runtime)
                cachedRuntime = runtime // Memory only, including the selected scheme.
                Self.logger.info("Antigravity quota refresh succeeded; groupCount=\(snapshot.groups.count, privacy: .public)")
                return snapshot
            } catch is CancellationError { throw CancellationError() }
            catch is AntigravityQuotaParserError { receivedUnrecognizedResponse = true }
            catch AntigravityQuotaClientError.protocolChanged { receivedUnrecognizedResponse = true }
            catch { try Task.checkCancellation(); continue }
        }
        if receivedUnrecognizedResponse { throw AntigravityQuotaClientError.protocolChanged }
        throw runtimes.isEmpty ? AntigravityQuotaClientError.runtimeUnavailable : AntigravityQuotaClientError.quotaUnavailable
    }

    private func read(_ runtime: Runtime) async throws -> AntigravityQuotaSnapshot {
        let data = try await rpc(runtime, Self.quotaPath, #"{"forceRefresh":true}"#)
        let status = try? await rpc(runtime, Self.userStatusPath, "{}")
        try Task.checkCancellation()
        return try AntigravityQuotaParser.parse(data: data, userStatusData: status)
    }

    private nonisolated static func discoverRuntimes() throws -> [Runtime] {
        let processIDs = try languageServerProcessIDs()
        guard !processIDs.isEmpty else { throw AntigravityQuotaClientError.notRunning }
        var runtimes: [Runtime] = []
        for processID in processIDs {
            guard let commandLine = try? commandLine(processID: processID),
                  let token = argumentValue(named: "--csrf_token", in: commandLine)
                    ?? argumentValue(named: "--csrf-token", in: commandLine),
                  !token.isEmpty, !token.contains(where: \.isNewline),
                  let endpoints = try? listeningEndpoints(processID: processID) else { continue }
            for endpoint in endpoints {
                for scheme in ["http", "https"] {
                    runtimes.append(Runtime(processID: processID, host: endpoint.host, port: endpoint.port, scheme: scheme, csrfToken: token))
                }
            }
        }
        return runtimes
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
              arguments.indices.contains(index + 1) else {
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
            .split(whereSeparator: \.isNewline) {
            if line.hasPrefix("n127.0.0.1:"),
               let port = Int(line.dropFirst("n127.0.0.1:".count)) {
                endpoints.append(LoopbackEndpoint(host: "127.0.0.1", port: port))
            } else if line.hasPrefix("n[::1]:"),
                      let port = Int(line.dropFirst("n[::1]:".count)) {
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
              let url = URL(string: "\(runtime.scheme)://\(runtime.host):\(runtime.port)\(path)") else {
            throw AntigravityQuotaClientError.runtimeUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(runtime.csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (bytes, response) = try await session.bytes(for: request, delegate: session.delegate as? LoopbackSessionDelegate)
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

private struct LoopbackEndpoint: Hashable, Sendable {
    let host: String
    let port: Int
}

private struct CommandResult: Sendable {
    let status: Int32
    let output: Data
}

/// Antigravity's existing local TLS service uses a self-signed certificate.
/// This exception cannot follow a redirect or authenticate any remote host.
private final class LoopbackSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           ["127.0.0.1", "::1", "[::1]"].contains(space.host), let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
