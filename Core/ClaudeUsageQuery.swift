import Foundation
import CoreFoundation

public enum ClaudeUsageQueryError: Error, LocalizedError, Equatable {
    case cliMissing, launchFailed, timeout, oversizedOutput, invalidOutput, invalidResetTime, modelResponse, loginRequired, noQuota, commandFailed
    public var errorDescription: String? {
        switch self {
        case .cliMissing: L10n.text("claude.query.error.cli_missing", fallback: "Claude CLI not found. Install Claude Code, then refresh.")
        case .launchFailed: L10n.text("claude.query.error.launch", fallback: "Claude CLI could not start.")
        case .timeout: L10n.text("claude.query.error.timeout", fallback: "Claude usage query timed out after 20 seconds. Try again.")
        case .oversizedOutput: L10n.text("claude.query.error.output_limit", fallback: "Claude /usage output exceeded the size limit.")
        case .invalidOutput: L10n.text("claude.query.error.output", fallback: "Claude /usage returned an unsupported format. Try refreshing again.")
        case .invalidResetTime: L10n.text("claude.query.error.reset_time", fallback: "Claude /usage returned a reset time that could not be verified. Try refreshing again.")
        case .modelResponse: L10n.text("claude.query.error.model", fallback: "Claude did not return a local /usage result. This response was discarded.")
        case .loginRequired: L10n.text("claude.query.error.login", fallback: "Sign in to Claude CLI with your subscription, then refresh.")
        case .noQuota: L10n.text("claude.query.error.no_quota", fallback: "Claude /usage returned no subscription limits. Check your CLI login and plan.")
        case .commandFailed: L10n.text("claude.query.error.failed", fallback: "Claude /usage failed. Check your CLI login and network, then refresh.")
        }
    }
}

/// The CLI owns authentication. The app reads only a zero-turn built-in result,
/// never a generated answer, cost estimate, transcript or authentication file.
public enum ClaudeUsageQueryParser {
    public static let outputLimit = 1_048_576
    public static func parse(_ data: Data, at now: Date) throws -> ClaudeCodeQuotaSnapshot {
        guard data.count <= outputLimit else { throw ClaudeUsageQueryError.oversizedOutput }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "result", let text = root["result"] as? String else {
            throw ClaudeUsageQueryError.invalidOutput
        }
        if root["is_error"] as? Bool == true {
            if text.localizedCaseInsensitiveContains("log in") || text.localizedCaseInsensitiveContains("login") || text.localizedCaseInsensitiveContains("authentication") {
                throw ClaudeUsageQueryError.loginRequired
            }
            throw ClaudeUsageQueryError.commandFailed
        }
        guard root["is_error"] as? Bool == false, root["subtype"] as? String == "success" else { throw ClaudeUsageQueryError.invalidOutput }
        guard number(root["num_turns"]) == 0, number(root["total_cost_usd"]) == 0,
              let models = root["modelUsage"] as? [String: Any], models.isEmpty else { throw ClaudeUsageQueryError.modelResponse }
        if let usage = root["usage"] as? [String: Any] {
            for key in ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] {
                if let value = usage[key], number(value) != 0 { throw ClaudeUsageQueryError.modelResponse }
            }
        }
        guard now.timeIntervalSince1970.isFinite else { throw ClaudeUsageQueryError.invalidOutput }
        var windows: [QuotaKind: ClaudeCodeQuotaReport] = [:]
        var seenKinds: Set<QuotaKind> = []
        for line in text.components(separatedBy: .newlines) {
            let kind: QuotaKind
            let prefix: String
            if line.hasPrefix("Current session:") { kind = .fiveHour; prefix = "Current session:" }
            else if line.hasPrefix("Current week (all models):") { kind = .sevenDay; prefix = "Current week (all models):" }
            else { continue }
            guard seenKinds.insert(kind).inserted,
                  let parts = match(#"^\s*(\d+(?:\.\d+)?)% used(?: · resets (.+))?$"#, String(line.dropFirst(prefix.count))),
                  let used = Double(parts[0]), used.isFinite, (0...100).contains(used) else { throw ClaudeUsageQueryError.invalidOutput }
            // A window without a reset time cannot be shown safely. It must
            // not prevent an independent, valid window from being returned.
            guard !parts[1].isEmpty else { continue }
            let reset = try resetDate(parts[1], kind: kind, at: now)
            guard reset > now else { continue }
            windows[kind] = ClaudeCodeQuotaReport(kind: kind, usedPercentage: used, resetsAt: reset, firstObservedAt: now)
        }
        // A recognized built-in result may have no active windows. Returning
        // that state clears previous numbers rather than retaining a false error.
        guard !seenKinds.isEmpty else { throw ClaudeUsageQueryError.noQuota }
        return ClaudeCodeQuotaSnapshot(fiveHour: windows[.fiveHour], sevenDay: windows[.sevenDay],
            sessionFingerprint: "usage-query", lastCallbackAt: now, source: .usageQuery)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<result.numberOfRanges).map {
            guard let range = Range(result.range(at: $0), in: text) else { return "" }
            return String(text[range])
        }
    }

    private static func resetDate(_ text: String, kind: QuotaKind, at now: Date) throws -> Date {
        guard let parts = match(#"^(.+) at (\d{1,2})(?::(\d{2}))?\s*(am|pm) \(([^()]+)\)$"#, text),
              let hour12 = Int(parts[1]), (1...12).contains(hour12),
              let minute = Int(parts[2].isEmpty ? "0" : parts[2]), (0...59).contains(minute),
              let zone = TimeZone(identifier: parts[4]) else { throw ClaudeUsageQueryError.invalidResetTime }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let hour = hour12 % 12 + (parts[3] == "pm" ? 12 : 0)
        let maximum = kind == .fiveHour ? 5 * 3_600.0 + 600 : 7 * 86_400.0 + 3_600
        let reference = calendar.dateComponents([.year, .month, .day], from: now)
        var candidates: [Date] = []
        if parts[0] == "Today" || parts[0] == "Tomorrow" {
            guard let day = calendar.date(byAdding: .day, value: parts[0] == "Tomorrow" ? 1 : 0, to: now),
                  let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { throw ClaudeUsageQueryError.invalidResetTime }
            candidates = [date]
            let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let expected = calendar.dateComponents([.year, .month, .day], from: day)
            guard actual.year == expected.year && actual.month == expected.month && actual.day == expected.day && actual.hour == hour && actual.minute == minute else { throw ClaudeUsageQueryError.invalidResetTime }
        } else {
            guard let dateParts = match(#"^([A-Za-z]+) (\d{1,2})(?:, (\d{4}))?$"#, parts[0]),
                  let monthIndex = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].firstIndex(of: dateParts[0]),
                  let day = Int(dateParts[1]), (1...31).contains(day), let currentYear = reference.year else { throw ClaudeUsageQueryError.invalidResetTime }
            let years = dateParts[2].isEmpty ? [currentYear - 1, currentYear, currentYear + 1] : [Int(dateParts[2]) ?? 0]
            for year in years {
                let components = DateComponents(year: year, month: monthIndex + 1, day: day, hour: hour, minute: minute, second: 0)
                if let date = calendar.date(from: components) {
                    let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                    if roundTrip.year == year && roundTrip.month == monthIndex + 1 && roundTrip.day == day && roundTrip.hour == hour && roundTrip.minute == minute { candidates.append(date) }
                }
            }
        }
        // Resolve an omitted year to the closest calendar date. A passed reset
        // is omitted above, even after a long idle period. Never roll it to a
        // future day or accept a future reset outside this window's horizon.
        guard let date = candidates.min(by: { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }),
              date.timeIntervalSince(now) <= maximum else { throw ClaudeUsageQueryError.invalidResetTime }
        let offsetChange = zone.secondsFromGMT(for: date.addingTimeInterval(86_400)) - zone.secondsFromGMT(for: date.addingTimeInterval(-86_400))
        if offsetChange < 0 {
            let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
            let components = calendar.dateComponents(fields, from: date)
            for delta in [Double(offsetChange), -Double(offsetChange)] {
                if calendar.dateComponents(fields, from: date.addingTimeInterval(delta)) == components { throw ClaudeUsageQueryError.invalidResetTime }
            }
        }
        return date
    }
}

public enum ClaudeUsageQueryCache {
    private struct Archive: Codable { let version: Int; let snapshot: ClaudeCodeQuotaSnapshot }
    public static var url: URL { ClaudeCodeStatusLineConfiguration.supportDirectory.appendingPathComponent("claude-usage-query-v1.json") }
    public static func read(from url: URL = url) throws -> ClaudeCodeQuotaSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let archive = try JSONDecoder().decode(Archive.self, from: ClaudeCodePrivateFile.read(url, limit: 16_384))
        guard archive.version == 1 else { throw ClaudeUsageQueryError.invalidOutput }
        try validate(archive.snapshot)
        return archive.snapshot
    }
    public static func write(_ snapshot: ClaudeCodeQuotaSnapshot, to url: URL = url) throws {
        try validate(snapshot)
        try ClaudeCodePrivateFile.atomicWrite(JSONEncoder().encode(Archive(version: 1, snapshot: snapshot)), to: url, permissions: 0o600)
    }
    private static func validate(_ snapshot: ClaudeCodeQuotaSnapshot) throws {
        guard snapshot.source == .usageQuery, snapshot.sessionFingerprint == "usage-query",
              snapshot.lastCallbackAt.timeIntervalSince1970.isFinite,
              snapshot.fiveHour == nil || snapshot.fiveHour?.kind == .fiveHour,
              snapshot.sevenDay == nil || snapshot.sevenDay?.kind == .sevenDay,
              snapshot.orderedReports.allSatisfy({
                  let horizon = $0.kind == .fiveHour ? 5 * 3_600.0 + 600 : 7 * 86_400.0 + 3_600
                  return $0.firstObservedAt == snapshot.lastCallbackAt && $0.usedPercentage.isFinite
                      && (0...100).contains($0.usedPercentage) && (-60...horizon).contains($0.resetsAt.timeIntervalSince(snapshot.lastCallbackAt))
              }) else { throw ClaudeUsageQueryError.invalidOutput }
    }
    public static func clear(at url: URL = url) throws {
        try ClaudeCodePrivateFile.rejectSymlink(url)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

public enum ClaudeUsageBinaryLocator {
    public static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser, path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> URL? {
        let candidates = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            + path.split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/claude" }
        return candidates.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }.first {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType) == .typeRegular
                && FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}
