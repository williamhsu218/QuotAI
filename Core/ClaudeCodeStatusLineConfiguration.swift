import Darwin
import Foundation

public enum ClaudeCodeConfigurationError: Error, LocalizedError {
    case invalidSettings, unsupportedStatusLine, recursiveCommand, invalidState, settingsChanged, symbolicLink, oversizedFile, lockTimeout, invalidHelper, invalidReports
    public var errorDescription: String? {
        switch self {
        case .invalidSettings: L10n.text("claude.error.invalid_settings", fallback: "Claude Code settings.json is unreadable or invalid.")
        case .unsupportedStatusLine: L10n.text("claude.error.unsupported_status_line", fallback: "The existing statusLine is not a supported command; it was left unchanged.")
        case .recursiveCommand: L10n.text("claude.error.recursive_command", fallback: "The existing status line references QuotAI's bridge; it was left unchanged.")
        case .invalidState: L10n.text("claude.error.invalid_state", fallback: "The bridge restoration state is invalid; settings were left unchanged.")
        case .settingsChanged: L10n.text("claude.error.settings_changed", fallback: "Claude Code settings were changed by another process; QuotAI did not overwrite them.")
        case .symbolicLink: L10n.text("claude.error.symbolic_link", fallback: "Symbolic links are not supported for bridge configuration files.")
        case .oversizedFile: L10n.text("claude.error.oversized_file", fallback: "The bridge configuration file exceeds its size limit.")
        case .lockTimeout: L10n.text("claude.error.lock_timeout", fallback: "The bridge file is busy; this callback was skipped.")
        case .invalidHelper: L10n.text("claude.error.invalid_helper", fallback: "The standalone QuotAI status-line helper is missing or its location is unsupported.")
        case .invalidReports: L10n.text("claude.error.invalid_reports", fallback: "The local Claude Code reports are invalid or belong to another configuration.")
        }
    }
}

public struct ClaudeCodeBridgeState: Codable, Equatable, Sendable {
    public let version: Int
    public var enabled: Bool
    public let helperPath: String
    public let installedCommand: String
    public let settingsPath: String
    public let configurationFingerprint: String
    public let sessionSalt: String
    public let previousStatusLineData: Data?
    public let installedStatusLineData: Data
    public let installedSettingsChecksum: String
    public let originalSettingsExisted: Bool
    public let originalSettingsChecksum: String?
    public let originalPermissions: Int
    public let originalBackupPath: String?

    public init(enabled: Bool, helperURL: URL, settingsURL: URL, sessionSalt: String = UUID().uuidString,
                previousStatusLineData: Data?, installedStatusLineData: Data, installedSettingsChecksum: String,
                originalSettingsExisted: Bool, originalPermissions: Int, originalBackupPath: String?, originalSettingsChecksum: String? = nil) {
        version = 2
        self.enabled = enabled
        helperPath = helperURL.path
        installedCommand = ClaudeCodeStatusLineConfiguration.command(helperURL: helperURL)
        settingsPath = settingsURL.path
        configurationFingerprint = ClaudeCodeRateLimitParser.hash(Data((settingsURL.path + "\u{0}" + sessionSalt).utf8))
        self.sessionSalt = sessionSalt
        self.previousStatusLineData = previousStatusLineData
        self.installedStatusLineData = installedStatusLineData
        self.installedSettingsChecksum = installedSettingsChecksum
        self.originalSettingsExisted = originalSettingsExisted
        self.originalSettingsChecksum = originalSettingsChecksum
        self.originalPermissions = originalPermissions
        self.originalBackupPath = originalBackupPath
    }
}

public enum ClaudeCodeConfigurationStatus: Equatable, Sendable {
    case notConfigured, connected, disabled, helperMoved, conflict(String)
}

public enum ClaudeCodeStatusLineConfiguration {
    public static let enabledDefaultsKey = "claudeCodeRateLimitBridgeEnabled"
    public static let bridgeEnvironmentKey = "QUOTAI_CLAUDE_BRIDGE"
    public static let helperName = "quotai-claude-statusline"
    public static let settingsLimit = 1_048_576
    public static let stateLimit = 65_536

    public static var settingsURL: URL { ClaudeStatusLineRetirement.settingsURL }
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuotAI", isDirectory: true)
    }
    public static var stateURL: URL { supportDirectory.appendingPathComponent("claude-rate-limits-bridge-v2.json") }
    public static var defaultHelperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + helperName)
    }

    public static func command(helperURL: URL) -> String {
        "'" + helperURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func readState(stateURL: URL = stateURL) throws -> ClaudeCodeBridgeState? {
        try ClaudeCodePrivateFile.rejectSymlink(stateURL)
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        let data = try ClaudeCodePrivateFile.read(stateURL, limit: stateLimit)
        guard let state = try? JSONDecoder().decode(ClaudeCodeBridgeState.self, from: data) else { throw ClaudeCodeConfigurationError.invalidState }
        guard state.version == 2, !state.sessionSalt.isEmpty, state.sessionSalt.utf8.count <= 128,
              state.settingsPath.hasPrefix("/"), state.helperPath.hasPrefix("/"),
              state.installedCommand == command(helperURL: URL(fileURLWithPath: state.helperPath)),
              state.configurationFingerprint == ClaudeCodeRateLimitParser.hash(Data((state.settingsPath + "\u{0}" + state.sessionSalt).utf8)),
              (0...0o777).contains(state.originalPermissions),
              let installed = try JSONSerialization.jsonObject(with: state.installedStatusLineData) as? [String: Any],
              installed["type"] as? String == "command", installed["command"] as? String == state.installedCommand else {
            throw ClaudeCodeConfigurationError.invalidState
        }
        if let previous = state.previousStatusLineData { _ = try supportedStatusLine(JSONSerialization.jsonObject(with: previous)) }
        return state
    }

    public static func check(helperURL: URL? = nil, settingsURL: URL = settingsURL, stateURL: URL = stateURL) -> ClaudeCodeConfigurationStatus {
        do {
            guard let state = try readState(stateURL: stateURL) else { return .notConfigured }
            guard state.enabled else { return .disabled }
            guard state.settingsPath == settingsURL.path else { return .conflict(ClaudeCodeConfigurationError.settingsChanged.localizedDescription) }
            if let helperURL, state.helperPath != helperURL.path { return .helperMoved }
            guard FileManager.default.isExecutableFile(atPath: state.helperPath) else { return .helperMoved }
            let settings = try settingsDictionary(ClaudeCodePrivateFile.read(settingsURL, limit: settingsLimit))
            guard let current = settings["statusLine"],
                  try json(current) == state.installedStatusLineData else { return .conflict(ClaudeCodeConfigurationError.settingsChanged.localizedDescription) }
            return .connected
        } catch { return .conflict(error.localizedDescription) }
    }

    @discardableResult
    public static func enable(helperURL: URL, settingsURL: URL = settingsURL, stateURL: URL = stateURL) throws -> ClaudeCodeBridgeState {
        guard helperURL.isFileURL, helperURL.path.hasPrefix("/"), helperURL.lastPathComponent == helperName,
              !helperURL.path.contains("AppTranslocation"), FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw ClaudeCodeConfigurationError.invalidHelper
        }
        return try ClaudeCodePrivateFile.withLock(at: stateURL.appendingPathExtension("lock")) {
            try ClaudeCodePrivateFile.rejectSymlink(settingsURL)
            let oldState = try readState(stateURL: stateURL)
            if let oldState, oldState.enabled {
                guard oldState.helperPath == helperURL.path,
                      check(helperURL: helperURL, settingsURL: settingsURL, stateURL: stateURL) == .connected else {
                    throw ClaudeCodeConfigurationError.settingsChanged
                }
                return oldState
            }
            let existed = FileManager.default.fileExists(atPath: settingsURL.path)
            let original = existed ? try ClaudeCodePrivateFile.read(settingsURL, limit: settingsLimit) : nil
            var settings = try original.map(settingsDictionary) ?? [:]
            let previous = try settings["statusLine"].map(supportedStatusLine)
            // A disabled hook can still be called by an open terminal, but must
            // be restored before a fresh installation is allowed.
            if let previous, previous["command"] as? String == oldState?.installedCommand {
                throw ClaudeCodeConfigurationError.settingsChanged
            }
            var installed = previous ?? ["type": "command"]
            installed["command"] = command(helperURL: helperURL)
            settings["statusLine"] = installed
            let updated = try settingsData(settings)
            let mode = existed ? try ClaudeCodePrivateFile.permissions(settingsURL) : 0o600
            let backup = existed ? settingsURL.appendingPathExtension("quotai-bridge-backup-" + UUID().uuidString) : nil
            if let original, let backup { try ClaudeCodePrivateFile.atomicWrite(original, to: backup, permissions: mode) }
            let state = ClaudeCodeBridgeState(enabled: true, helperURL: helperURL, settingsURL: settingsURL,
                previousStatusLineData: try previous.map(json), installedStatusLineData: try json(installed),
                installedSettingsChecksum: ClaudeCodeRateLimitParser.hash(updated), originalSettingsExisted: existed,
                originalPermissions: mode, originalBackupPath: backup?.path,
                originalSettingsChecksum: original.map(ClaudeCodeRateLimitParser.hash))
            try saveState(state, stateURL: stateURL)
            do {
                try compareSettings(settingsURL, original: original)
                try ClaudeCodePrivateFile.atomicWrite(updated, to: settingsURL, permissions: mode)
            } catch {
                if let oldState { try? saveState(oldState, stateURL: stateURL) }
                else { try? FileManager.default.removeItem(at: stateURL) }
                throw error
            }
            return state
        }
    }

    /// Disables recording first. Even when the user's edit prevents restoring
    /// settings, open terminals keep their original command passthrough.
    public static func disable(settingsURL: URL = settingsURL, stateURL: URL = stateURL) throws {
        try ClaudeCodePrivateFile.withLock(at: stateURL.appendingPathExtension("lock")) {
            guard var state = try readState(stateURL: stateURL) else { return }
            state.enabled = false
            try saveState(state, stateURL: stateURL)
            guard state.settingsPath == settingsURL.path else { throw ClaudeCodeConfigurationError.settingsChanged }
            let original = try ClaudeCodePrivateFile.read(settingsURL, limit: settingsLimit)
            var settings = try settingsDictionary(original)
            guard let current = settings["statusLine"], try json(current) == state.installedStatusLineData else {
                throw ClaudeCodeConfigurationError.settingsChanged
            }
            let backup = settingsURL.appendingPathExtension("quotai-restore-backup-" + UUID().uuidString)
            let mode = try ClaudeCodePrivateFile.permissions(settingsURL)
            try ClaudeCodePrivateFile.atomicWrite(original, to: backup, permissions: mode)
            let updated: Data?
            let restoredMode: Int
            if ClaudeCodeRateLimitParser.hash(original) == state.installedSettingsChecksum {
                if state.originalSettingsExisted {
                    guard let backupPath = state.originalBackupPath,
                          URL(fileURLWithPath: backupPath).deletingLastPathComponent() == settingsURL.deletingLastPathComponent(),
                          URL(fileURLWithPath: backupPath).lastPathComponent.hasPrefix(settingsURL.lastPathComponent + ".quotai-bridge-backup-") else {
                        throw ClaudeCodeConfigurationError.invalidState
                    }
                    let restoration = try ClaudeCodePrivateFile.read(URL(fileURLWithPath: backupPath), limit: settingsLimit)
                    guard let checksum = state.originalSettingsChecksum, ClaudeCodeRateLimitParser.hash(restoration) == checksum else {
                        throw ClaudeCodeConfigurationError.invalidState
                    }
                    _ = try settingsDictionary(restoration)
                    updated = restoration
                } else { updated = nil }
                restoredMode = state.originalPermissions
            } else {
                if let previous = state.previousStatusLineData { settings["statusLine"] = try JSONSerialization.jsonObject(with: previous) }
                else { settings.removeValue(forKey: "statusLine") }
                updated = try settingsData(settings)
                restoredMode = mode
            }
            try compareSettings(settingsURL, original: original)
            if let updated { try ClaudeCodePrivateFile.atomicWrite(updated, to: settingsURL, permissions: restoredMode) }
            else { try FileManager.default.removeItem(at: settingsURL) }
        }
    }

    public static func previousCommand(stateURL: URL = stateURL) -> String? {
        guard let state = try? readState(stateURL: stateURL), let data = state.previousStatusLineData,
              let statusLine = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = statusLine["command"] as? String else { return nil }
        return command
    }

    private static func supportedStatusLine(_ value: Any) throws -> [String: Any] {
        guard let statusLine = value as? [String: Any], statusLine["type"] as? String == "command",
              let command = statusLine["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.utf8.count <= 16_384 else { throw ClaudeCodeConfigurationError.unsupportedStatusLine }
        guard !command.contains(helperName), !command.contains("--claude-statusline"), !command.contains("--claude-rate-limits") else {
            throw ClaudeCodeConfigurationError.recursiveCommand
        }
        guard try json(statusLine).count <= 32_768 else { throw ClaudeCodeConfigurationError.oversizedFile }
        return statusLine
    }

    private static func settingsDictionary(_ data: Data) throws -> [String: Any] {
        guard let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeCodeConfigurationError.invalidSettings }
        return dictionary
    }
    private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func settingsData(_ settings: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        data.append(0x0A)
        guard data.count <= settingsLimit else { throw ClaudeCodeConfigurationError.oversizedFile }
        return data
    }
    private static func saveState(_ state: ClaudeCodeBridgeState, stateURL: URL) throws {
        let data = try JSONEncoder().encode(state)
        guard data.count <= stateLimit else { throw ClaudeCodeConfigurationError.oversizedFile }
        try ClaudeCodePrivateFile.atomicWrite(data, to: stateURL, permissions: 0o600)
    }
    private static func compareSettings(_ url: URL, original: Data?) throws {
        try ClaudeCodePrivateFile.rejectSymlink(url)
        if let original {
            guard try ClaudeCodePrivateFile.read(url, limit: settingsLimit) == original else { throw ClaudeCodeConfigurationError.settingsChanged }
        } else if FileManager.default.fileExists(atPath: url.path) { throw ClaudeCodeConfigurationError.settingsChanged }
    }
}

/// Bounded, regular-file IO and same-directory atomic replacement. Ancestor
/// symlinks are rejected, so a private filename cannot escape through a link.
enum ClaudeCodePrivateFile {
    static func rejectSymlink(_ url: URL) throws {
        // Foundation's standardizedFileURL turns /private/var into /var on
        // macOS, reintroducing an ancestor symlink after callers resolve it.
        var current = url
        while current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { throw ClaudeCodeConfigurationError.symbolicLink }
            current.deleteLastPathComponent()
        }
    }
    static func read(_ url: URL, limit: Int) throws -> Data {
        try rejectSymlink(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ClaudeCodeConfigurationError.invalidState }
        guard info.st_size <= limit else { throw ClaudeCodeConfigurationError.oversizedFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ClaudeCodeConfigurationError.oversizedFile }
        return data
    }
    static func permissions(_ url: URL) throws -> Int {
        try rejectSymlink(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
    }
    static func atomicWrite(_ data: Data, to url: URL, permissions: Int) throws {
        try rejectSymlink(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rejectSymlink(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".quotai-write-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var renamed = false
        defer { close(fd); if !renamed { unlink(temporary.path) } }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                written += count
            }
        }
        guard fchmod(fd, mode_t(permissions)) == 0, fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try rejectSymlink(url)
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        renamed = true
    }
    static func withLock<T>(at url: URL, operation: () throws -> T) throws -> T {
        try rejectSymlink(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        let deadline = DispatchTime.now().uptimeNanoseconds + 50_000_000
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw CocoaError(.fileWriteUnknown) }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ClaudeCodeConfigurationError.lockTimeout }
            usleep(1_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }
}
