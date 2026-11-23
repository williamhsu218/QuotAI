import CoreFoundation
import CryptoKit
import Foundation

struct LocalTokenUsageResult: Equatable, Sendable {
    let activity: TokenActivity?
    let isPartial: Bool
    let hasArchivedHistory: Bool

    init(activity: TokenActivity?, isPartial: Bool, hasArchivedHistory: Bool = false) {
        self.activity = activity
        self.isPartial = isPartial
        self.hasArchivedHistory = hasArchivedHistory
    }
}

/// Reads local session records for the selected provider and, when configured with
/// a private ledger URL, archives daily token totals for deleted session files so
/// removing a conversation never erases recorded token activity.
actor LocalTokenUsageReader {
    private struct FileStamp: Codable, Equatable {
        let size: Int
        let modifiedMillis: Int64
    }

    private struct Sample {
        let date: Date
        let tokens: Int64
    }

    private struct FileUsage {
        let stamp: FileStamp
        var days: [String: Int64] = [:]
        var messages: [String: Sample] = [:]
        var isPartial = false
    }

    private struct DiscoveredFile {
        let url: URL
        let rootID: String
        let key: String
    }

    private struct DiscoveryResult {
        let files: [DiscoveredFile]
        let healthyRoots: Set<String>
    }

    private struct DailyMessageUsage: Codable, Equatable {
        let day: String
        let tokens: Int64
    }

    private struct TrackedFile: Codable, Equatable {
        let rootID: String
        let stamp: FileStamp?
        let timeZoneIdentifier: String
        let days: [String: Int64]
        let messages: [String: DailyMessageUsage]?
        var isArchived = false
    }

    private struct LedgerArchive: Codable {
        static let currentVersion = 1
        var version: Int = currentVersion
        var providers: [String: [String: TrackedFile]] = [:]
    }

    private static let recordLimit = 16 * 1024 * 1024
    private static let ledgerLimit = 32 * 1024 * 1024
    private static let metadataKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey
    ]

    private let home: URL
    private let claudeDirectory: URL?
    private let ledgerURL: URL?
    private var cache: [QuotaProvider: [URL: FileUsage]] = [:]
    private var ledger: LedgerArchive?
    private var ledgerNeedsSave = false
    private var timeZone: TimeZone?

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        claudeConfigDirectory: String? = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
        ledgerURL: URL? = nil
    ) {
        self.home = home
        claudeDirectory = claudeConfigDirectory.flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)
        }
        self.ledgerURL = ledgerURL
    }

    func hasSavedHistory() -> Bool {
        if let ledger, !ledger.providers.isEmpty { return true }
        return ledgerURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func clearHistory() throws {
        if let ledgerURL {
            do {
                let values = try ledgerURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try FileManager.default.removeItem(at: ledgerURL)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                // A ledger that was never written is already clear.
            }
        }
        cache.removeAll()
        ledger = LedgerArchive()
        ledgerNeedsSave = false
    }

    func read(
        _ provider: QuotaProvider, now: Date = Date(), calendar: Calendar = .current
    ) throws -> LocalTokenUsageResult {
        guard provider == .antigravity || provider == .claudeCode else {
            return LocalTokenUsageResult(activity: nil, isPartial: false)
        }
        if timeZone != calendar.timeZone {
            timeZone = calendar.timeZone
            cache.removeAll()
        }
        let dates = UsageDates(timeZone: calendar.timeZone)
        var partial = false

        if let ledgerURL, ledger == nil {
            do {
                let loaded =
                    try PrivateJSONFile.read(LedgerArchive.self, from: ledgerURL, maximumBytes: Self.ledgerLimit)
                    ?? LedgerArchive()
                guard loaded.version == LedgerArchive.currentVersion else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                ledger = loaded
            } catch {
                // Keep the on-disk ledger intact if it cannot be read. Try again on the next scan.
                partial = true
            }
        }

        let discovery = try discoverFiles(provider, partial: &partial)
        let previous = ledger?.providers[provider.rawValue] ?? [:]
        var trackedFiles = previous
        var scanned: [URL: FileUsage] = [:]
        var foundFiles: Set<String> = []
        var filesWithFreshMessages: Set<String> = []
        var liveMessages: [String: Sample] = [:]

        for discovered in discovery.files {
            try Task.checkCancellation()
            let file = discovered.url
            foundFiles.insert(discovered.key)
            do {
                let metadata = try file.resourceValues(forKeys: Self.metadataKeys)
                guard metadata.isRegularFile == true, metadata.isSymbolicLink == false,
                    let size = metadata.fileSize, let modified = metadata.contentModificationDate
                else {
                    partial = true
                    continue
                }
                let stamp = FileStamp(size: size, modifiedMillis: Self.millis(modified))
                let cached = cache[provider]?[file]
                let saved = previous[discovered.key]
                let usage: FileUsage
                if let cached, cached.stamp == stamp, !cached.isPartial {
                    usage = cached
                } else if provider == .antigravity, let saved, saved.stamp == stamp,
                    saved.timeZoneIdentifier == calendar.timeZone.identifier
                {
                    usage = FileUsage(stamp: stamp, days: saved.days)
                } else {
                    usage = try readFile(file, provider: provider, stamp: stamp, dates: dates)
                }
                scanned[file] = usage
                if usage.isPartial {
                    partial = true
                    if saved != nil { continue }
                }
                guard !usage.days.isEmpty || !usage.messages.isEmpty else {
                    trackedFiles.removeValue(forKey: discovered.key)
                    continue
                }
                filesWithFreshMessages.insert(discovered.key)
                for (id, sample) in usage.messages {
                    if let old = liveMessages[id], (old.date, old.tokens) >= (sample.date, sample.tokens) { continue }
                    liveMessages[id] = sample
                }
                if var saved, saved.stamp == stamp, saved.timeZoneIdentifier == calendar.timeZone.identifier {
                    saved.isArchived = false
                    trackedFiles[discovered.key] = saved
                } else {
                    let savedMessages = usage.messages.mapValues {
                        DailyMessageUsage(day: dates.day.string(from: $0.date), tokens: $0.tokens)
                    }
                    trackedFiles[discovered.key] = TrackedFile(
                        rootID: discovered.rootID,
                        stamp: usage.isPartial ? nil : stamp,
                        timeZoneIdentifier: calendar.timeZone.identifier,
                        days: usage.days,
                        messages: savedMessages.isEmpty ? nil : savedMessages
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                partial = true
            }
        }
        try Task.checkCancellation()
        cache[provider] = scanned

        for (key, var tracked) in previous where !tracked.isArchived && !foundFiles.contains(key) {
            if discovery.healthyRoots.contains(tracked.rootID) {
                tracked.isArchived = true
                trackedFiles[key] = tracked
            } else {
                partial = true
            }
        }

        if var archive = ledger, trackedFiles != previous {
            archive.providers[provider.rawValue] = trackedFiles.isEmpty ? nil : trackedFiles
            ledger = archive
            ledgerNeedsSave = true
        }
        if ledgerNeedsSave, let ledger, let ledgerURL {
            do {
                try PrivateJSONFile.write(ledger, to: ledgerURL, maximumBytes: Self.ledgerLimit)
                ledgerNeedsSave = false
            } catch {
                partial = true
            }
        }

        let (days, hasArchivedHistory) = Self.aggregate(
            files: trackedFiles, filesWithFreshMessages: filesWithFreshMessages,
            liveMessages: liveMessages, dates: dates
        )
        let today = dates.day.string(from: now)
        let buckets = days.keys.filter { $0 <= today }.sorted().map {
            DailyUsageBucket(startDate: $0, tokens: days[$0, default: 0])
        }
        guard !buckets.isEmpty else {
            return LocalTokenUsageResult(
                activity: nil, isPartial: partial, hasArchivedHistory: hasArchivedHistory)
        }
        let summary = AccountTokenUsageSummary(
            lifetimeTokens: buckets.reduce(0) { Self.sum($0, $1.tokens) },
            currentStreakDays: currentStreak(days, now: now, dates: dates),
            peakDailyTokens: buckets.map(\.tokens).max())
        return LocalTokenUsageResult(
            activity: TokenActivity(dailyUsageBuckets: buckets, summary: summary),
            isPartial: partial,
            hasArchivedHistory: hasArchivedHistory)
    }

    private static func aggregate(
        files: [String: TrackedFile], filesWithFreshMessages: Set<String>, liveMessages: [String: Sample],
        dates: UsageDates
    ) -> (days: [String: Int64], hasArchivedHistory: Bool) {
        var days: [String: Int64] = [:]
        var hasArchivedHistory = false
        var messages = liveMessages.mapValues {
            (usage: DailyMessageUsage(day: dates.day.string(from: $0.date), tokens: $0.tokens), archived: false)
        }
        for (key, file) in files {
            for (day, tokens) in file.days where tokens > 0 {
                days[day] = sum(days[day, default: 0], tokens)
                hasArchivedHistory = hasArchivedHistory || file.isArchived
            }
            // A deleted transcript can share Claude message IDs with a live copy.
            guard !filesWithFreshMessages.contains(key), let savedMessages = file.messages else { continue }
            for (id, usage) in savedMessages where usage.tokens > 0 {
                if let old = messages[id] {
                    let existing = (old.usage.day, old.usage.tokens)
                    let candidate = (usage.day, usage.tokens)
                    if existing > candidate || (existing == candidate && !old.archived) { continue }
                }
                messages[id] = (usage, file.isArchived)
            }
        }
        for (usage, archived) in messages.values {
            days[usage.day] = sum(days[usage.day, default: 0], usage.tokens)
            hasArchivedHistory = hasArchivedHistory || archived
        }
        return (days, hasArchivedHistory)
    }

    private func discoverFiles(_ provider: QuotaProvider, partial: inout Bool) throws -> DiscoveryResult {
        let roots: [(id: String, url: URL)]
        switch provider {
        case .claudeCode:
            let root = (claudeDirectory ?? home.appendingPathComponent(".claude")).appendingPathComponent("projects")
            roots = [("claude:" + Self.digest(root.standardizedFileURL.path), root)]
        case .antigravity:
            roots = [
                ("antigravity", home.appendingPathComponent(".gemini/antigravity")),
                ("antigravity-cli", home.appendingPathComponent(".gemini/antigravity-cli")),
                ("antigravity-ide", home.appendingPathComponent(".antigravity-ide"))
            ]
        default:
            return DiscoveryResult(files: [], healthyRoots: [])
        }

        let manager = FileManager.default
        var files: [DiscoveredFile] = []
        var healthyRoots: Set<String> = []
        for (rootID, root) in roots {
            guard manager.fileExists(atPath: root.path) else { continue }
            // Do not follow redirected session trees into unrelated directories.
            guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().path else {
                partial = true
                continue
            }
            var traversalFailed = false
            // Antigravity stores its request logs below hidden directories.
            let options: FileManager.DirectoryEnumerationOptions =
                provider == .antigravity ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
            guard
                let enumerator = manager.enumerator(
                    at: root, includingPropertiesForKeys: Array(Self.metadataKeys),
                    options: options,
                    errorHandler: { _, _ in
                        traversalFailed = true
                        return true
                    })
            else {
                partial = true
                continue
            }
            let rootComponentsCount = root.standardizedFileURL.pathComponents.count
            for case let file as URL in enumerator {
                try Task.checkCancellation()
                guard let metadata = try? file.resourceValues(forKeys: Self.metadataKeys) else {
                    traversalFailed = true
                    enumerator.skipDescendants()
                    continue
                }
                if metadata.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard metadata.isRegularFile == true else { continue }
                let ext = file.pathExtension.lowercased()
                let include: Bool
                if provider == .claudeCode {
                    include = ext == "jsonl"
                } else if ext == "jsonl" || ext == "json" {
                    let folders = file.deletingLastPathComponent().pathComponents.dropFirst(root.pathComponents.count)
                    include = folders.contains(where: { ["logs", "sessions", "chats"].contains($0) })
                } else {
                    include = false
                }
                if include {
                    let relativePath = file.standardizedFileURL.pathComponents
                        .dropFirst(rootComponentsCount)
                        .joined(separator: "/")
                    let key = Self.digest("\(provider.rawValue)|\(rootID)|\(relativePath)")
                    files.append(DiscoveredFile(url: file, rootID: rootID, key: key))
                }
            }
            if !traversalFailed {
                healthyRoots.insert(rootID)
            }
            partial = partial || traversalFailed
        }
        return DiscoveryResult(files: files, healthyRoots: healthyRoots)
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func digest(_ text: String) -> String {
        Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString()
    }

    private func readFile(
        _ file: URL, provider: QuotaProvider, stamp: FileStamp, dates: UsageDates
    ) throws -> FileUsage {
        var usage = FileUsage(stamp: stamp)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        func consume(_ data: Data) {
            // Many transcript rows contain only prompts or tool output.
            guard
                Self.usageMarkers.contains(where: { data.range(of: $0) != nil }),
                let json = try? JSONSerialization.jsonObject(with: data)
            else { return }
            collect(json, provider: provider, dates: dates, usage: &usage)
        }

        if file.pathExtension.lowercased() == "json" {
            if stamp.size > Self.recordLimit {
                usage.isPartial = true
            } else {
                consume(try handle.read(upToCount: stamp.size) ?? Data())
            }
            return usage
        }

        // Bound each line, and read up to the size seen at discovery even if
        // the agent is still appending to the transcript.
        var remainder = stamp.size
        var pending = Data()
        var droppingLine = false
        while remainder > 0 {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(remainder, 256 * 1024)), !chunk.isEmpty else { break }
            remainder -= chunk.count
            let fragments = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
            for (index, fragment) in fragments.enumerated() {
                if !droppingLine && pending.count + fragment.count <= Self.recordLimit {
                    pending.append(fragment)
                } else {
                    pending.removeAll(keepingCapacity: false)
                    droppingLine = true
                    usage.isPartial = true
                }
                if index != fragments.count - 1 {
                    if !droppingLine { consume(pending) }
                    pending.removeAll(keepingCapacity: true)
                    droppingLine = false
                }
            }
        }
        if !droppingLine && !pending.isEmpty { consume(pending) }
        if remainder > 0 { usage.isPartial = true }
        return usage
    }

    private static let usageMarkers = [
        "usage", "tokens", "usageMetadata",
        "total_tokens", "totalTokens", "totalTokenCount", "prompt_tokens", "promptTokenCount",
        "input_tokens", "output_tokens", "inputTokens", "outputTokens"
    ].map { Data(("\"" + $0 + "\"").utf8) }

    private func collect(
        _ value: Any, provider: QuotaProvider, dates: UsageDates, usage: inout FileUsage
    ) {
        if let records = value as? [Any] {
            for record in records { collect(record, provider: provider, dates: dates, usage: &usage) }
            return
        }
        guard let record = value as? [String: Any] else { return }
        if let records = record["messages"] as? [Any] {
            collect(records, provider: provider, dates: dates, usage: &usage)
            return
        }
        let message = record["message"] as? [String: Any]
        let payload =
            provider == .claudeCode
            ? (message ?? record)
            : (message ?? record["data"] as? [String: Any] ?? record["payload"] as? [String: Any] ?? record)
        let counters: [String: Any]
        if let nested = payload["usage"] as? [String: Any] {
            counters = nested
        } else if provider == .antigravity {
            counters = payload["tokens"] as? [String: Any] ?? payload["usageMetadata"] as? [String: Any] ?? payload
        } else {
            return
        }
        let tokens = Self.total(counters)
        guard tokens > 0 else { return }
        guard let date = dates.timestamp(record) ?? dates.timestamp(payload) else {
            usage.isPartial = true
            return
        }
        if provider == .claudeCode, let id = payload["id"] as? String, !id.isEmpty {
            // Claude writes cumulative usage for successive updates to one message.
            usage.messages[Self.digest(id)] = Sample(date: date, tokens: tokens)
        } else {
            let day = dates.day.string(from: date)
            usage.days[day] = Self.sum(usage.days[day, default: 0], tokens)
        }
    }

    private static func total(_ counters: [String: Any]) -> Int64 {
        func count(_ keys: String...) -> Int64? {
            keys.lazy.compactMap { key -> Int64? in
                guard let number = counters[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                    let value = Int64(number.stringValue), value >= 0
                else { return nil }
                return value
            }.first
        }
        if let total = count("total_tokens", "totalTokens", "totalTokenCount", "total") { return total }
        if let prompt = count("promptTokenCount") {
            let output = count("candidatesTokenCount") ?? 0
            return sum(sum(prompt, output), count("thoughtsTokenCount", "thoughts") ?? 0)
        }
        if let prompt = count("prompt_tokens") {
            return sum(prompt, count("completion_tokens") ?? 0)
        }
        let input = count("input_tokens", "inputTokens", "input") ?? 0
        let output = count("output_tokens", "outputTokens", "output") ?? 0
        let cacheRead = count("cache_read_input_tokens", "cache_read_tokens", "cacheReadTokens") ?? 0
        let cacheWrite = count("cache_creation_input_tokens", "cache_creation_tokens", "cacheCreationTokens") ?? 0
        let cache = count("cached") == nil ? cacheRead : 0
        return sum(sum(input, output), sum(cache, cacheWrite))
    }

    private static func sum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }

    private func currentStreak(_ days: [String: Int64], now: Date, dates: UsageDates) -> Int {
        var date = now
        if days[dates.day.string(from: date)] == nil,
            let yesterday = dates.calendar.date(byAdding: .day, value: -1, to: date)
        {
            date = yesterday
        }
        var streak = 0
        while days[dates.day.string(from: date), default: 0] > 0 {
            streak += 1
            guard let previous = dates.calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
        return streak
    }
}

private struct UsageDates {
    let calendar: Calendar
    let day: DateFormatter
    private let iso = ISO8601DateFormatter()
    private let isoFractional = ISO8601DateFormatter()

    init(timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = calendar
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func timestamp(_ record: [String: Any]) -> Date? {
        for key in ["timestamp", "created_at", "createdAt", "time", "date"] {
            if let text = record[key] as? String {
                if let date = isoFractional.date(from: text) ?? iso.date(from: text) { return date }
                if text.count == 10, let date = day.date(from: text) { return date }
            } else if let number = record[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                let value = number.doubleValue
                if value.isFinite, value >= 0, value < 100_000_000_000_000 {
                    return Date(timeIntervalSince1970: value >= 100_000_000_000 ? value / 1_000 : value)
                }
            }
        }
        return nil
    }
}
