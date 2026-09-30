import Foundation

/// Filesystem and subprocess regression probe using temporary executables only.
/// Compile with Core/*.swift and App/Services/CodexBinaryLocator.swift.
@main
struct CodexBinaryLocatorProbe {
    static func main() throws {
        let fileManager = FileManager.default
        let fixture = fileManager.temporaryDirectory.appendingPathComponent(
            "quotai-locator-\(UUID().uuidString)", isDirectory: true
        )
        try fileManager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixture) }

        let application = fixture.appendingPathComponent("ChatGPT.app")
        let desktop = application.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        let legacyDesktop = application.appendingPathComponent("Contents/Resources/codex")
        let cliDirectory = fixture.appendingPathComponent("cli")
        let cli = cliDirectory.appendingPathComponent("codex")
        let pathDirectory = fixture.appendingPathComponent("path")
        let pathAlias = pathDirectory.appendingPathComponent("codex")
        // An empty fixture PATH makes the missing-Node case deterministic even
        // on machines that also install Node in a system directory.
        let restrictedEnvironment = ["PATH": fixture.appendingPathComponent("finder-path").path]

        func executable(_ url: URL, contents: String) throws {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func candidates(customPath: String? = nil, path: String? = nil) throws -> [URL] {
            try CodexBinaryLocator.candidates(
                customPath: customPath,
                applicationPaths: [application.path],
                commandDirectories: [cliDirectory.path],
                environment: path.map { ["PATH": $0] } ?? [:]
            )
        }

        func runVersion(_ url: URL) throws -> (status: Int32, output: String) {
            let process = Process()
            let output = Pipe()
            process.executableURL = url
            process.arguments = ["--version"]
            process.environment = restrictedEnvironment
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        try executable(desktop, contents: "#!/bin/sh\n/bin/echo mock-desktop\n")
        try executable(cli, contents: "#!/usr/bin/env node\nconsole.log('mock-node-cli');\n")
        let brokenCLI = try runVersion(cli)
        precondition(brokenCLI.status == 127, "Fixture must reproduce Node being absent from Finder's PATH")
        let desktopCandidates = try candidates()
        precondition(desktopCandidates == [desktop, cli])
        let desktopVersion = try runVersion(desktopCandidates[0])
        precondition(desktopVersion.status == 0 && desktopVersion.output == "mock-desktop")
        print("PASS desktop wrapper is preferred when the CLI requires unavailable Node")

        let customCandidates = try candidates(customPath: cli.path)
        precondition(customCandidates == [cli])
        do {
            _ = try candidates(customPath: fixture.appendingPathComponent("missing").path)
            preconditionFailure("An invalid custom path must not fall back to automatic discovery")
        } catch CodexBinaryLocatorError.invalidCustomPath {}
        print("PASS custom path remains a strict override")

        try fileManager.createDirectory(at: pathDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: pathAlias, withDestinationURL: desktop)
        let deduplicatedCandidates = try candidates(path: pathDirectory.path)
        precondition(deduplicatedCandidates == [desktop, cli])
        print("PASS duplicate PATH symlinks retain the preferred desktop entry only")

        try fileManager.removeItem(at: desktop)
        try executable(legacyDesktop, contents: "#!/bin/sh\n/bin/echo mock-legacy-desktop\n")
        let legacyCandidates = try candidates()
        precondition(legacyCandidates == [legacyDesktop, cli])
        let legacyVersion = try runVersion(legacyCandidates[0])
        precondition(legacyVersion.status == 0 && legacyVersion.output == "mock-legacy-desktop")
        print("PASS legacy desktop layout is retained")

        try fileManager.removeItem(at: legacyDesktop)
        try executable(cli, contents: "#!/bin/sh\n/bin/echo mock-cli\n")
        let cliCandidates = try candidates()
        precondition(cliCandidates == [cli])
        let cliVersion = try runVersion(cliCandidates[0])
        precondition(cliVersion.status == 0 && cliVersion.output == "mock-cli")
        print("PASS standalone CLI remains available without a desktop installation")

        try fileManager.removeItem(at: cli)
        do {
            _ = try candidates()
            preconditionFailure("Missing executables must be reported")
        } catch CodexBinaryLocatorError.notFound {}
        print("PASS no executable is reported as not found")
    }
}
