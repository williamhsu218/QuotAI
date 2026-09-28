import Foundation
import Testing
@testable import QuotAICore

@Suite("Antigravity installation detection")
struct ProviderInstallationTests {
    @Test("Empty homes and leftover Antigravity data do not count as installed")
    func leftoverData() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        #expect(!fixture.antigravity())
        try fixture.directory(".antigravity")
        try fixture.directory(".gemini/antigravity")
        try fixture.file("Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
        #expect(!fixture.antigravity())
    }

    @Test("Installed and renamed app bundles are detected by identity",
          arguments: ["Antigravity.app", "Antigravity Personal.app"])
    func installedBundle(name: String) throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        try fixture.application(name)
        #expect(fixture.antigravity())
    }

    @Test("Empty or unrelated app bundles do not enable Antigravity")
    func invalidBundles() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        try fixture.directory("Applications/Antigravity.app")
        #expect(!fixture.antigravity())
        try fixture.application("Antigravity.app", identifier: "com.example.unrelated")
        #expect(!fixture.antigravity())
    }

    @Test("Missing, non-executable, and directory executables are rejected")
    func invalidBundleExecutables() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let bundle = try fixture.application("Antigravity.app", executablePermissions: 0o644)
        #expect(!fixture.antigravity())
        let executable = bundle.appendingPathComponent("Contents/MacOS/Provider")
        try FileManager.default.removeItem(at: executable)
        #expect(!fixture.antigravity())
        try FileManager.default.createDirectory(at: executable, withIntermediateDirectories: true)
        #expect(!fixture.antigravity())
    }

    @Test("The declared executable cannot use an empty name or path traversal",
          arguments: ["", ".", "..", "../Provider", "/Provider"])
    func invalidExecutableName(name: String) throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let bundle = try fixture.application("Antigravity.app")
        try fixture.file("Applications/Antigravity.app/Contents/Provider", permissions: 0o755)
        let declaredName = name == "/Provider"
            ? try fixture.file("Provider", permissions: 0o755).path
            : name
        try fixture.writeInfo(bundle, identifier: "com.google.antigravity", executableName: declaredName)
        #expect(!fixture.antigravity())
    }

    @Test("Antigravity disappears after uninstall even when data remains")
    func antigravityUninstall() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        let bundle = try fixture.application("Antigravity.app")
        try fixture.file("Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
        #expect(fixture.antigravity())
        try FileManager.default.removeItem(at: bundle)
        #expect(!fixture.antigravity())
    }

    @Test("Explicit empty application directories replace default locations")
    func injectedLocationsReplaceDefaults() throws {
        let fixture = try InstallationFixture()
        defer { fixture.remove() }
        try fixture.application("Antigravity.app")
        #expect(fixture.antigravity())
        #expect(!ProviderInstallationDetector.antigravity(homeDirectory: fixture.home,
                                                         applicationDirectories: []))
    }
}

private struct InstallationFixture {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotAI-installation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }

    @discardableResult
    func directory(_ path: String) throws -> URL {
        let url = home.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ path: String, permissions: Int = 0o644) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        return url
    }

    @discardableResult
    func application(_ name: String, identifier: String = "com.google.antigravity",
                     executablePermissions: Int = 0o755) throws -> URL {
        let bundle = try directory("Applications/\(name)/Contents/MacOS")
            .deletingLastPathComponent().deletingLastPathComponent()
        try writeInfo(bundle, identifier: identifier, executableName: "Provider")
        try file("Applications/\(name)/Contents/MacOS/Provider", permissions: executablePermissions)
        return bundle
    }

    func writeInfo(_ bundle: URL, identifier: String, executableName: String) throws {
        let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": executableName]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    func antigravity() -> Bool {
        ProviderInstallationDetector.antigravity(homeDirectory: home,
            applicationDirectories: [home.appendingPathComponent("Applications", isDirectory: true)])
    }
}
