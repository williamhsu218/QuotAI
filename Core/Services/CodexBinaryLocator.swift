import Foundation

enum CodexBinaryLocatorError: LocalizedError {
    case invalidCustomPath(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case let .invalidCustomPath(path):
            L10n.format(
                "error.binary.invalid_path_format",
                fallback: "The configured Codex path is not executable: %@",
                path
            )
        case .notFound:
            L10n.text(
                "error.binary.not_found",
                fallback: "Codex was not found on this Mac. Install or sign in to ChatGPT/Codex, or specify the Codex path in Settings."
            )
        }
    }
}

enum CodexBinaryLocator {
    static func candidates(
        customPath: String?,
        applicationPaths: [String] = [
            "/Applications/ChatGPT.app",
            "/Applications/Codex.app"
        ],
        commandDirectories: [String] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            NSString(string: "~/.local/bin").expandingTildeInPath
        ],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [URL] {
        let fileManager = FileManager.default

        if let customPath, !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = NSString(string: customPath).expandingTildeInPath
            guard fileManager.isExecutableFile(atPath: expanded) else {
                throw CodexBinaryLocatorError.invalidCustomPath(customPath)
            }
            return [URL(fileURLWithPath: expanded)]
        }

        // The desktop wrapper resolves its bundled native executable without
        // requiring Node on the Finder-launched app's PATH.
        var candidates = applicationPaths.map {
            URL(fileURLWithPath: $0)
                .appendingPathComponent("Contents/Resources/codex-cli/bin/codex").path
        }
        candidates.append(contentsOf: applicationPaths.map {
            URL(fileURLWithPath: $0)
                .appendingPathComponent("Contents/Resources/codex").path
        })
        candidates.append(contentsOf: commandDirectories.map {
            URL(fileURLWithPath: $0).appendingPathComponent("codex").path
        })

        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path
            })
        }
        var seenPaths = Set<String>()
        let executables = candidates.compactMap { path -> URL? in
            guard fileManager.isExecutableFile(atPath: path) else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let identity = url.resolvingSymlinksInPath().path
            guard seenPaths.insert(identity).inserted else { return nil }
            return url
        }

        guard !executables.isEmpty else {
            throw CodexBinaryLocatorError.notFound
        }
        return executables
    }

    static func locate(customPath: String?) throws -> URL {
        try candidates(customPath: customPath)[0]
    }
}
