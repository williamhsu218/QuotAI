import Foundation
import Darwin
import Testing
@testable import QuotAICore

struct ClaudeCodeConfigurationTests {
    @Test("Installation preserves other settings and all status-line options, restoration is byte-exact with original permissions")
    func installAndRestore() throws {
        let fixture = try ClaudeCodeTestFixture()
        defer { fixture.remove() }
        let previous: [String: Any] = ["type": "command", "command": "printf '%s' 'original'", "padding": 3, "refreshInterval": 17, "userOption": "keep"]
        let original = try fixture.write(["statusLine": previous, "env": ["PRESERVE": "value"], "permissions": ["allow": ["Read"]]], permissions: 0o640)
        let state = try fixture.enable()
        #expect(state.enabled)
        #expect(try fixture.permissions(fixture.settings) == 0o640)
        #expect(try fixture.permissions(fixture.state) == 0o600)
        #expect(try Data(contentsOf: #require(state.originalBackupPath.map { URL(fileURLWithPath: $0) })) == original)
        #expect(try fixture.permissions(#require(state.originalBackupPath.map { URL(fileURLWithPath: $0) })) == 0o640)
        let settings = try fixture.read()
        let statusLine = try #require(settings["statusLine"] as? [String: Any])
        #expect(statusLine["padding"] as? Int == 3)
        #expect(statusLine["refreshInterval"] as? Int == 17)
        #expect(statusLine["userOption"] as? String == "keep")
        #expect(settings["env"] as? [String: String] == ["PRESERVE": "value"])
        #expect(ClaudeCodeStatusLineConfiguration.check(helperURL: fixture.helper, settingsURL: fixture.settings, stateURL: fixture.state) == .connected)
        #expect(ClaudeCodeStatusLineConfiguration.previousCommand(stateURL: fixture.state) == previous["command"] as? String)
        #expect(try fixture.enable() == state)
        try fixture.disable()
        #expect(try Data(contentsOf: fixture.settings) == original)
        #expect(try fixture.permissions(fixture.settings) == 0o640)
        #expect(try ClaudeCodeStatusLineConfiguration.readState(stateURL: fixture.state)?.enabled == false)
        // Open terminals retain their original passthrough even after disable.
        #expect(ClaudeCodeStatusLineConfiguration.previousCommand(stateURL: fixture.state) == previous["command"] as? String)
    }

    @Test("Absent settings restore to absence; reconnect uses a different isolated configuration generation")
    func absentSettingsAndReconnect() throws {
        let fixture = try ClaudeCodeTestFixture()
        defer { fixture.remove() }
        let first = try fixture.enable()
        #expect(try fixture.permissions(fixture.settings) == 0o600)
        #expect(first.previousStatusLineData == nil)
        try fixture.disable()
        #expect(!FileManager.default.fileExists(atPath: fixture.settings.path))
        let second = try fixture.enable()
        #expect(second.configurationFingerprint != first.configurationFingerprint)
        #expect(second.sessionSalt != first.sessionSalt)
    }

    @Test("Unrelated user edits survive restoration while status-line edits stop replacement and recording")
    func userChanges() throws {
        let fixture = try ClaudeCodeTestFixture()
        defer { fixture.remove() }
        _ = try fixture.write(["statusLine": ["type": "command", "command": "cat"], "original": true])
        _ = try fixture.enable()
        var settings = try fixture.read()
        settings["userAdded"] = "preserved"
        _ = try fixture.write(settings)
        try fixture.disable()
        let restored = try fixture.read()
        #expect(restored["userAdded"] as? String == "preserved")
        #expect((restored["statusLine"] as? [String: Any])?["command"] as? String == "cat")
        _ = try fixture.enable()
        settings = try fixture.read()
        var line = try #require(settings["statusLine"] as? [String: Any])
        line["padding"] = 99
        settings["statusLine"] = line
        let edited = try fixture.write(settings)
        #expect(throws: (any Error).self) { try fixture.disable() }
        #expect(try Data(contentsOf: fixture.settings) == edited)
        #expect(try ClaudeCodeStatusLineConfiguration.readState(stateURL: fixture.state)?.enabled == false)
        #expect(throws: (any Error).self) { try fixture.enable() }
        #expect(try Data(contentsOf: fixture.settings) == edited)
    }

    @Test("Unsupported, malformed, recursive, and oversized settings never get overwritten")
    func unsupportedConfigurations() throws {
        let badLines: [Any] = [NSNull(), "text", [:], ["type": "prompt", "command": "cat"], ["type": "command"],
            ["command": "cat"], ["type": "command", "command": " \n"], ["type": "command", "command": 4],
            ["type": "command", "command": "wrapper --claude-statusline"],
            ["type": "command", "command": "wrapper --claude-rate-limits"],
            ["type": "command", "command": "'/old/quotai-claude-statusline'"],
            ["type": "command", "command": String(repeating: "x", count: 16_385)]]
        for line in badLines {
            let fixture = try ClaudeCodeTestFixture()
            defer { fixture.remove() }
            let original = try fixture.write(["statusLine": line, "keep": true])
            #expect(throws: (any Error).self) { try fixture.enable() }
            #expect(try Data(contentsOf: fixture.settings) == original)
            #expect(!FileManager.default.fileExists(atPath: fixture.state.path))
        }
        let fixture = try ClaudeCodeTestFixture()
        defer { fixture.remove() }
        for original in [Data("{broken".utf8), Data("[]".utf8), Data(repeating: 32, count: 1_048_577)] {
            try original.write(to: fixture.settings)
            #expect(throws: (any Error).self) { try fixture.enable() }
            #expect(try Data(contentsOf: fixture.settings) == original)
        }
    }

    @Test("Settings, state, and parent symlinks fail closed")
    func symbolicLinks() throws {
        for role in ["settings", "state", "parent"] {
            let fixture = try ClaudeCodeTestFixture()
            defer { fixture.remove() }
            let original = try fixture.write(["keep": true])
            if role == "parent" {
                let target = fixture.root.appendingPathComponent("actual", isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let link = fixture.root.appendingPathComponent("linked", isDirectory: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
                #expect(throws: (any Error).self) { try ClaudeCodeStatusLineConfiguration.enable(helperURL: fixture.helper, settingsURL: link.appendingPathComponent("settings.json"), stateURL: fixture.state) }
            } else {
                let url = role == "settings" ? fixture.settings : fixture.state
                if role == "state" { try Data("{}".utf8).write(to: url) }
                let target = fixture.root.appendingPathComponent("target-" + role)
                try FileManager.default.moveItem(at: url, to: target)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
                #expect(throws: (any Error).self) { try fixture.enable() }
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target.path)
            }
            #expect(try Data(contentsOf: fixture.settings) == original)
        }
    }

    @Test("Legacy retirement ignores the standalone helper and missing helpers are never installed")
    func legacyAndHelperBoundaries() throws {
        let fixture = try ClaudeCodeTestFixture()
        defer { fixture.remove() }
        let state = try fixture.enable()
        #expect(!ClaudeStatusLineRetirement.isOwnedCommand(state.installedCommand))
        let bytes = try Data(contentsOf: fixture.settings)
        #expect(try !ClaudeStatusLineRetirement.retireIfNeeded(settingsURL: fixture.settings, stateURL: fixture.root.appendingPathComponent("legacy.json")))
        #expect(try Data(contentsOf: fixture.settings) == bytes)
        try fixture.disable()
        try FileManager.default.removeItem(at: fixture.helper)
        #expect(throws: (any Error).self) { try fixture.enable() }
    }

    @Test("A damaged original backup never replaces working settings")
    func damagedBackup() throws {
        let fixture = try ClaudeCodeTestFixture()
        defer { fixture.remove() }
        _ = try fixture.write(["keep": "original"])
        let state = try fixture.enable()
        let installed = try Data(contentsOf: fixture.settings)
        let backup = try #require(state.originalBackupPath.map { URL(fileURLWithPath: $0) })
        try Data("{broken".utf8).write(to: backup)
        #expect(throws: (any Error).self) { try fixture.disable() }
        #expect(try Data(contentsOf: fixture.settings) == installed)
        #expect(try ClaudeCodeStatusLineConfiguration.readState(stateURL: fixture.state)?.enabled == false)
    }
}

struct ClaudeCodeTestFixture {
    let root: URL
    var settings: URL { root.appendingPathComponent("settings.json") }
    var state: URL { root.appendingPathComponent("state.json") }
    var reports: URL { root.appendingPathComponent("reports.json") }
    var helper: URL { root.appendingPathComponent(ClaudeCodeStatusLineConfiguration.helperName) }
    init() throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        // Foundation may canonicalize /private/var back to /var; POSIX
        // realpath retains the literal regular-directory path for these tests.
        guard let resolved = realpath(temporary.path, nil) else { throw CocoaError(.fileReadUnknown) }
        let path = String(cString: resolved)
        free(resolved)
        root = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("QuotAI-Claude-v2-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    @discardableResult func write(_ value: [String: Any], permissions: Int = 0o600) throws -> Data {
        var data = Data(" \n\t".utf8)
        data.append(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
        data.append(Data("\n\n".utf8))
        try data.write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: settings.path)
        return data
    }
    func read() throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]) }
    func permissions(_ url: URL) throws -> Int { try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue }
    func enable() throws -> ClaudeCodeBridgeState { try ClaudeCodeStatusLineConfiguration.enable(helperURL: helper, settingsURL: settings, stateURL: state) }
    func disable() throws { try ClaudeCodeStatusLineConfiguration.disable(settingsURL: settings, stateURL: state) }
}
