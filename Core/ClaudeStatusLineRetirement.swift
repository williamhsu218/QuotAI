import Foundation

/// Compatibility for status-line hooks installed by QuotAI 2.0.14.
/// Restores only an exact owned command; never reads or writes usage reports.
public enum ClaudeStatusLineRetirement {
    public static let bridgeEnvironmentKey = "QUOTAI_CLAUDE_BRIDGE"

    public enum RetirementError: Error {
        case unreadableSettings, missingPreviousState, settingsChanged
    }

    public static var settingsURL: URL {
        let directory: URL
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        }
        return directory.appendingPathComponent("settings.json")
    }

    public static var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuotAI/claude-statusline.json")
    }

    public static func isOwnedCommand(_ command: String) -> Bool {
        let suffix = " --claude-statusline"
        guard command.hasSuffix(suffix) else { return false }
        let quoted = String(command.dropLast(suffix.count))
        guard quoted.first == "'", quoted.last == "'", quoted.count >= 2 else { return false }
        let path = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        let regenerated = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" + suffix
        return path.hasPrefix("/") && path.hasSuffix(".app/Contents/MacOS/QuotAI") && regenerated == command
    }

    @discardableResult
    public static func retireIfNeeded(settingsURL: URL = settingsURL, stateURL: URL = stateURL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path) else { return false }
        let original = try boundedData(settingsURL, limit: 1_048_576)
        guard var settings = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw RetirementError.unreadableSettings
        }
        guard let statusLine = settings["statusLine"] as? [String: Any],
              statusLine["type"] as? String == "command",
              let command = statusLine["command"] as? String,
              isOwnedCommand(command) else { return false }
        guard let state = try? JSONSerialization.jsonObject(with: boundedData(stateURL, limit: 65_536)) as? [String: Any],
              let previous = state["previousStatusLine"],
              previous is NSNull || previous is [String: Any] else {
            throw RetirementError.missingPreviousState
        }
        if let previous = previous as? [String: Any] {
            guard !(previous["command"] as? String ?? "").contains("--claude-statusline") else {
                throw RetirementError.missingPreviousState
            }
            settings["statusLine"] = previous
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        let backup = settingsURL.appendingPathExtension("quotai-retired-backup-" + UUID().uuidString)
        try fm.copyItem(at: settingsURL, to: backup)
        // Preserve the source permissions and a backup; never overwrite edits
        // observed while preparing the restoration.
        guard try boundedData(settingsURL, limit: 1_048_576) == original else {
            throw RetirementError.settingsChanged
        }
        var updated = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        updated.append(0x0A)
        try updated.write(to: settingsURL, options: .atomic)
        // Keep migration state for a terminal already invoking the old hook.
        return true
    }

    public static func previousCommand(stateURL: URL = stateURL) -> String? {
        guard let data = try? boundedData(stateURL, limit: 65_536),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let previous = state["previousStatusLine"] as? [String: Any],
              (previous["type"] as? String ?? "command") == "command",
              let command = previous["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !command.contains("--claude-statusline") else { return nil }
        return command
    }

    private static func boundedData(_ url: URL, limit: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= limit else {
            throw RetirementError.unreadableSettings
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw RetirementError.unreadableSettings }
        return data
    }
}
