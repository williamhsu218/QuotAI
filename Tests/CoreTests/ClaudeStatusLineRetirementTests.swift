import Foundation
import Testing
@testable import QuotAICore

@Suite("Retired Claude status-line compatibility")
struct ClaudeStatusLineRetirementTests {
    @Test("Ownership requires the exact quoted QuotAI hook command")
    func exactOwnership() {
        for command in [
            "'/Applications/QuotAI.app/Contents/MacOS/QuotAI' --claude-statusline",
            "'/Users/example/My Apps/QuotAI.app/Contents/MacOS/QuotAI' --claude-statusline",
            "'/Users/example/It'\\''s QuotAI.app/Contents/MacOS/QuotAI' --claude-statusline"
        ] {
            #expect(ClaudeStatusLineRetirement.isOwnedCommand(command))
        }
        for command in Self.customCommands {
            #expect(!ClaudeStatusLineRetirement.isOwnedCommand(command))
        }
    }

    @Test("Restoration keeps unrelated settings, original bytes, private permissions and state",
          arguments: [0o600, 0o640])
    func restoresPreviousStatusLine(permissions: Int) throws {
        let fixture = try RetirementFixture()
        defer { fixture.remove() }
        let previous: [String: Any] = ["type": "command", "command": "printf '%s' 'my status'", "padding": 2]
        let original = try fixture.writeSettings(permissions: permissions)
        let state = try fixture.writeState(["previousStatusLine": previous, "retainedMetadata": "fixture"])

        #expect(try fixture.retire())
        let restored = try fixture.readSettings()
        #expect(NSDictionary(dictionary: try #require(restored["statusLine"] as? [String: Any]))
            .isEqual(to: previous))
        #expect(NSDictionary(dictionary: restored.filter { $0.key != "statusLine" })
            .isEqual(to: RetirementFixture.unrelatedSettings))
        #expect(try fixture.permissions(fixture.settings) == permissions)
        let backup = try #require(fixture.backups().onlyElement)
        #expect(try Data(contentsOf: backup) == original)
        #expect(try fixture.permissions(backup) == permissions)
        #expect(try Data(contentsOf: fixture.state) == state)

        let firstResult = try Data(contentsOf: fixture.settings)
        let firstAttributes = try FileManager.default.attributesOfItem(atPath: fixture.settings.path)
        #expect(try !fixture.retire())
        #expect(try Data(contentsOf: fixture.settings) == firstResult)
        let secondAttributes = try FileManager.default.attributesOfItem(atPath: fixture.settings.path)
        #expect(firstAttributes[.systemFileNumber] as? NSNumber == secondAttributes[.systemFileNumber] as? NSNumber)
        #expect(firstAttributes[.modificationDate] as? Date == secondAttributes[.modificationDate] as? Date)
        #expect(try fixture.backups() == [backup])
        #expect(try Data(contentsOf: fixture.state) == state)
    }

    @Test("Explicit null previous state removes only the installed statusLine key")
    func removesPreviouslyAbsentStatusLine() throws {
        let fixture = try RetirementFixture()
        defer { fixture.remove() }
        let original = try fixture.writeSettings()
        let state = try fixture.writeState(["previousStatusLine": NSNull()])
        #expect(try fixture.retire())
        #expect(NSDictionary(dictionary: try fixture.readSettings()).isEqual(to: RetirementFixture.unrelatedSettings))
        #expect(try Data(contentsOf: #require(fixture.backups().onlyElement)) == original)
        #expect(try Data(contentsOf: fixture.state) == state)
        #expect(try !fixture.retire())
        #expect(try fixture.backups().count == 1)
    }

    @Test("Custom status lines and user wrappers are left byte-for-byte unchanged")
    func customCommandsAreUntouched() throws {
        for command in Self.customCommands {
            let fixture = try RetirementFixture()
            defer { fixture.remove() }
            let original = try fixture.writeSettings(command: command)
            // No state exists: a custom command must be ignored before loading state.
            #expect(try !fixture.retire())
            #expect(try Data(contentsOf: fixture.settings) == original)
            #expect(try fixture.backups().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.state.path))
        }
    }

    @Test("Missing, malformed or recursive restoration state fails closed")
    func invalidPreviousState() throws {
        let invalidStates: [Data?] = [
            nil,
            Data("{broken".utf8),
            Data("{}".utf8),
            Data("[]".utf8),
            try RetirementFixture.json(["previousStatusLine": "custom"]),
            try RetirementFixture.json(["previousStatusLine": ["not", "a", "dictionary"]]),
            try RetirementFixture.json(["previousStatusLine": 4]),
            try RetirementFixture.json(["previousStatusLine": ["type": "command", "command": RetirementFixture.ownedCommand]]),
            try RetirementFixture.json(["previousStatusLine": ["type": "command", "command": "wrapper --claude-statusline --extra"]]),
            Data(repeating: 0x20, count: 65_537)
        ]
        for state in invalidStates {
            let fixture = try RetirementFixture()
            defer { fixture.remove() }
            let original = try fixture.writeSettings()
            if let state { try state.write(to: fixture.state) }
            #expect(throws: (any Error).self) { try fixture.retire() }
            #expect(try Data(contentsOf: fixture.settings) == original)
            #expect(try fixture.backups().isEmpty)
            if let state {
                #expect(try Data(contentsOf: fixture.state) == state)
            } else {
                #expect(!FileManager.default.fileExists(atPath: fixture.state.path))
            }
        }
    }

    @Test("Absent, malformed and oversized settings never cause replacement")
    func invalidSettings() throws {
        let fixture = try RetirementFixture()
        defer { fixture.remove() }
        #expect(try !fixture.retire())
        for original in [Data("{broken".utf8), Data("[]".utf8), Data(repeating: 0x20, count: 1_048_577)] {
            try original.write(to: fixture.settings)
            #expect(throws: (any Error).self) { try fixture.retire() }
            #expect(try Data(contentsOf: fixture.settings) == original)
            #expect(try fixture.backups().isEmpty)
        }
    }

    @Test("Legacy hook passthrough accepts only a nonempty nonrecursive command")
    func previousCommandFiltering() throws {
        let fixture = try RetirementFixture()
        defer { fixture.remove() }
        #expect(ClaudeStatusLineRetirement.previousCommand(stateURL: fixture.state) == nil)
        for previous: [String: Any] in [
            ["type": "command", "command": "printf '%s' 'custom status'"],
            ["command": "  printf '%s' 'kept spaces'  "]
        ] {
            try fixture.writeState(["previousStatusLine": previous])
            #expect(ClaudeStatusLineRetirement.previousCommand(stateURL: fixture.state) == previous["command"] as? String)
        }
        for previous: Any in [
            NSNull(), "plain string", [String: Any](),
            ["type": "prompt", "command": "custom"],
            ["type": "command", "command": " \n\t"],
            ["type": "command", "command": 1],
            ["command": RetirementFixture.ownedCommand],
            ["command": "wrapper --claude-statusline --user-flag"]
        ] {
            try fixture.writeState(["previousStatusLine": previous])
            #expect(ClaudeStatusLineRetirement.previousCommand(stateURL: fixture.state) == nil)
        }
        for data in [Data("{broken".utf8), Data(repeating: 0x20, count: 65_537)] {
            try data.write(to: fixture.state)
            #expect(ClaudeStatusLineRetirement.previousCommand(stateURL: fixture.state) == nil)
        }
    }

    @Test("Settings and restoration state symlinks are rejected without following them")
    func symlinksFailClosed() throws {
        for useSettingsLink in [true, false] {
            let fixture = try RetirementFixture()
            defer { fixture.remove() }
            let original = try fixture.writeSettings()
            let state = try fixture.writeState(["previousStatusLine": NSNull()])
            let linkedURL = useSettingsLink ? fixture.settings : fixture.state
            let target = fixture.root.appendingPathComponent("link-target.json")
            try FileManager.default.moveItem(at: linkedURL, to: target)
            try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: target)
            #expect(throws: (any Error).self) { try fixture.retire() }
            #expect(try Data(contentsOf: fixture.settings) == original)
            #expect(try Data(contentsOf: fixture.state) == state)
            #expect(try fixture.backups().isEmpty)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkedURL.path) == target.path)
            if !useSettingsLink {
                #expect(ClaudeStatusLineRetirement.previousCommand(stateURL: fixture.state) == nil)
            }
        }
    }

    private static let customCommands = [
        "printf 'custom'",
        "'/Applications/QuotAI.app/Contents/MacOS/QuotAI' --claude-statusline --my-flag",
        "env FLAG=1 '/Applications/QuotAI.app/Contents/MacOS/QuotAI' --claude-statusline",
        "'/Applications/QuotAI.app/Contents/MacOS/QuotAI' --claude-statusline | cat",
        "'/Applications/QuotAI.app/Contents/MacOS/QuotAI' --claude-statusline; printf done",
        "'/Applications/QuotAI.app/Contents/MacOS/QuotAI' --claude-statusline ",
        "'/Applications/QuotAI.app/Contents/MacOS/QuotAI' --claude-statusline\n",
        "'Applications/QuotAI.app/Contents/MacOS/QuotAI' --claude-statusline",
        "/Applications/QuotAI.app/Contents/MacOS/QuotAI --claude-statusline",
        "\"/Applications/QuotAI.app/Contents/MacOS/QuotAI\" --claude-statusline",
        "'/Applications/QuotAI.app/Contents/MacOS/Other' --claude-statusline",
        "'/Applications/QuotAI/Contents/MacOS/QuotAI' --claude-statusline",
        "'/Applications/QuotAI.app/Contents/MacOS/QuotAI'  --claude-statusline"
    ]
}

private struct RetirementFixture {
    let root: URL
    var settings: URL { root.appendingPathComponent("settings.json") }
    var state: URL { root.appendingPathComponent("state.json") }
    static let ownedCommand = "'/Applications/QuotAI.app/Contents/MacOS/QuotAI' --claude-statusline"
    static var unrelatedSettings: [String: Any] { [
        "env": ["EXAMPLE": "preserved", "SECOND": "line\nvalue"],
        "permissions": ["allow": ["Read", "Bash(swift test:*)"], "deny": ["Write(private/**)"]],
        "enabled": true, "retryCount": 3, "nothing": NSNull()
    ] }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotAI-retirement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    @discardableResult
    func writeSettings(command: String = ownedCommand, permissions: Int = 0o600) throws -> Data {
        var settings = Self.unrelatedSettings
        settings["statusLine"] = ["type": "command", "command": command, "padding": 0]
        // Deliberately keep noncanonical whitespace so byte-preserving backups
        // cannot pass by serializing the same logical JSON again.
        var data = Data(" \n\t".utf8)
        data.append(try Self.json(settings))
        data.append(Data("\n\n".utf8))
        try data.write(to: self.settings)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: self.settings.path)
        return data
    }

    @discardableResult
    func writeState(_ value: [String: Any]) throws -> Data {
        let data = try Self.json(value)
        try data.write(to: state)
        return data
    }

    func readSettings() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
    }

    func retire() throws -> Bool {
        try ClaudeStatusLineRetirement.retireIfNeeded(settingsURL: settings, stateURL: state)
    }

    func backups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("settings.json.quotai-retired-backup-") }
    }

    func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

private extension Array {
    var onlyElement: Element? { count == 1 ? first : nil }
}
