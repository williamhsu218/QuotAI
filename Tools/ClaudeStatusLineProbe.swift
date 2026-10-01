import Foundation

/// Exercises the shipped helper against synthetic settings and reports.
/// Never uses the user's Claude configuration or conversations.
@main
enum ClaudeStatusLineProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw ProbeError.failure("usage: ClaudeStatusLineProbe <helper>")
        }
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = helper.deletingLastPathComponent().appendingPathComponent("QuotAI-ClaudeProbe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("settings.json")
        let state = directory.appendingPathComponent("state.json")
        let reports = directory.appendingPathComponent("reports.json")
        let captured = directory.appendingPathComponent("captured")
        let previous: [String: Any] = ["type": "command", "command": "/usr/bin/tee " + quote(captured.path), "padding": 2]
        let original = try JSONSerialization.data(withJSONObject: ["statusLine": previous, "unrelated": "keep"])
        try original.write(to: settings)
        let installed = try ClaudeCodeStatusLineConfiguration.enable(helperURL: helper, settingsURL: settings, stateURL: state)

        var environment = ProcessInfo.processInfo.environment
        environment["QUOTAI_CLAUDE_V2_STATE"] = state.path
        environment["QUOTAI_CLAUDE_V2_REPORTS"] = reports.path
        let now = Date().timeIntervalSince1970.rounded(.down)
        func input(padding: Int, session: String = "synthetic-session") throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "session_id": session,
                "version": "2.1.285",
                "rate_limits": [
                    "five_hour": ["used_percentage": 42.0, "resets_at": now + 3600],
                    "seven_day": ["used_percentage": 19.0, "resets_at": now + 5 * 86400]
                ],
                "cwd": "private-cwd-must-not-persist",
                "transcript_path": "private-transcript-must-not-persist",
                "cost": ["total_cost_usd": 1234],
                "padding": String(repeating: "x", count: padding)
            ])
        }
        func run(_ data: Data, tag: String) throws -> (Data, Int32) {
            let file = directory.appendingPathComponent("input-" + tag)
            try data.write(to: file)
            let source = try FileHandle(forReadingFrom: file)
            defer { try? source.close() }
            let process = Process()
            process.executableURL = helper
            process.environment = environment
            process.standardInput = source
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (bytes, process.terminationStatus)
        }
        for size in [100, 8192, 16384, 2 * 1_048_576] {
            let data = try input(padding: size)
            let (out, status) = try run(data, tag: String(size))
            try require(status == 0 && out == data, "passthrough \(size)")
            try require(try Data(contentsOf: captured) == data, "previous command stdin \(size)")
        }
        let recorded = try Data(contentsOf: reports)
        let archive = try ClaudeCodeReportRepository.read(configurationFingerprint: installed.configurationFingerprint, reportsURL: reports)
        try require(archive.snapshots.count == 1 && archive.snapshots.first?.fiveHour?.usedPercentage == 42
            && archive.snapshots.first?.sevenDay?.usedPercentage == 19, "official quota fields recorded")
        let text = String(decoding: recorded, as: UTF8.self)
        try require(!text.contains("private-cwd") && !text.contains("private-transcript") && !text.contains("total_cost_usd") && !text.contains("padding"), "report whitelist")
        _ = try JSONSerialization.jsonObject(with: recorded)
        let malformed = Data("{invalid JSON but previous command must still receive it".utf8)
        let (out, status) = try run(malformed, tag: "malformed")
        try require(status == 0 && out == malformed, "malformed input passthrough")
        try require(try Data(contentsOf: reports) == recorded, "malformed input cannot change reports")

        try ClaudeCodeStatusLineConfiguration.disable(settingsURL: settings, stateURL: state)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        try require(NSDictionary(dictionary: restored["statusLine"] as! [String: Any]).isEqual(to: previous), "previous status line restoration")
        let disabledInput = try input(padding: 120)
        let (disabledOut, disabledStatus) = try run(disabledInput, tag: "disabled")
        try require(disabledStatus == 0 && disabledOut == disabledInput, "open terminal still passes through after disable")
        try require(try Data(contentsOf: reports) == recorded, "disabled helper cannot collect")
        print("PASS: helper passthrough (small, pipe threshold, large, above collection limit), whitelist, malformed input, restore, disabled collection")
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ProbeError.failure(message) }
    }
    private enum ProbeError: Error { case failure(String) }
}
