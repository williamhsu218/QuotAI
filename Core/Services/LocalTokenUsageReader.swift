import CoreFoundation
import Foundation

struct LocalTokenUsageResult: Equatable, Sendable {
    let activity: TokenActivity?
    let isPartial: Bool
}

/// Reads only the local session records for the selected provider. Cache entries
/// contain dates and counts, so unchanged transcripts are not parsed on each refresh.
actor LocalTokenUsageReader {
    private struct FileStamp: Equatable {
        let size: Int
        let modified: Date
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

    private static let recordLimit = 16 * 1024 * 1024
    private static let metadataKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey
    ]

    private let home: URL
    private let claudeDirectory: URL?
    private var cache: [QuotaProvider: [URL: FileUsage]] = [:]
    private var timeZone: TimeZone?

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        claudeConfigDirectory: String? = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
    ) {
        self.home = home
        claudeDirectory = claudeConfigDirectory.flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)
        }
    }

    func read(
        _ provider: QuotaProvider, now: Date = Date(), calendar: Calendar = .current
    ) throws -> LocalTokenUsageResult {
        if timeZone != calendar.timeZone {
            timeZone = calendar.timeZone
            cache.removeAll()
        }
        let dates = UsageDates(timeZone: calendar.timeZone)
        var partial = false
        let files = try discoverFiles(provider, partial: &partial)
        var scanned: [URL: FileUsage] = [:]
        var days: [String: Int64] = [:]
        var messages: [String: Sample] = [:]
        for file in files {
            try Task.checkCancellation()
            do {
                let metadata = try file.resourceValues(forKeys: Self.metadataKeys)
                guard metadata.isRegularFile == true, metadata.isSymbolicLink == false,
                    let size = metadata.fileSize, let modified = metadata.contentModificationDate
                else {
                    continue
                }
                let stamp = FileStamp(size: size, modified: modified)
                let previous = cache[provider]?[file]
                let usage: FileUsage
                if let previous, previous.stamp == stamp {
                    usage = previous
                } else {
                    usage = try readFile(file, provider: provider, stamp: stamp, dates: dates)
                    cache[provider, default: [:]][file] = usage
                }
                scanned[file] = usage
                partial = partial || usage.isPartial
                for (day, tokens) in usage.days { days[day] = Self.sum(days[day, default: 0], tokens) }
                for (id, sample) in usage.messages {
                    if let existing = messages[id] {
                        if existing.date > sample.date { continue }
                        if existing.date == sample.date && existing.tokens >= sample.tokens { continue }
                    }
                    messages[id] = sample
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                partial = true
            }
        }
        try Task.checkCancellation()
        cache[provider] = scanned
        for sample in messages.values {
            let day = dates.day.string(from: sample.date)
            days[day] = Self.sum(days[day, default: 0], sample.tokens)
        }
        let today = dates.day.string(from: now)
        let buckets = days.keys.filter { $0 <= today }.sorted().map {
            DailyUsageBucket(startDate: $0, tokens: days[$0, default: 0])
        }
        guard !buckets.isEmpty else { return LocalTokenUsageResult(activity: nil, isPartial: partial) }
        let summary = AccountTokenUsageSummary(
            lifetimeTokens: buckets.reduce(0) { Self.sum($0, $1.tokens) },
            currentStreakDays: currentStreak(days, now: now, dates: dates),
            peakDailyTokens: buckets.map(\.tokens).max())
        return LocalTokenUsageResult(
            activity: TokenActivity(dailyUsageBuckets: buckets, summary: summary), isPartial: partial)
    }

    private func discoverFiles(_ provider: QuotaProvider, partial: inout Bool) throws -> [URL] {
        let roots: [URL]
        switch provider {
        case .claudeCode:
            roots = [(claudeDirectory ?? home.appendingPathComponent(".claude")).appendingPathComponent("projects")]
        case .antigravity:
            roots = [".gemini/antigravity", ".gemini/antigravity-cli", ".antigravity-ide"].map {
                home.appendingPathComponent($0)
            }
        default:
            return []
        }

        let manager = FileManager.default
        var files: [URL] = []
        for root in roots {
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
                if provider == .claudeCode {
                    if ext == "jsonl" { files.append(file) }
                } else if ext == "jsonl" || ext == "json" {
                    let folders = file.deletingLastPathComponent().pathComponents.dropFirst(root.pathComponents.count)
                    if folders.contains(where: { ["logs", "sessions", "chats"].contains($0) }) {
                        files.append(file)
                    }
                }
            }
            partial = partial || traversalFailed
        }
        return files
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
        return usage
    }

    private static let usageMarkers = [
        "usage", "tokens", "usageMetadata", "input_tokens", "output_tokens", "inputTokens", "outputTokens"
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
            usage.messages[id] = Sample(date: date, tokens: tokens)
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
