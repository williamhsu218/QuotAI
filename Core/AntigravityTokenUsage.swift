import CryptoKit
import Foundation

/// Local generation metadata, not account-wide quota or a billing ledger.
public struct AntigravityTokenModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let input: Int64
    public let output: Int64 // Includes thinking; never add thinking a second time.
    public let cacheRead: Int64
    public let generations: Int
    public var processed: Int64 { input + output }
    /// Recorded input + output + cache hits; not a provider billing metric.
    public var total: Int64 { processed + cacheRead }
}

public enum AntigravityTokenFormat {
    /// M as the minimum unit, automatically promoted to B at display precision.
    public static func compact(_ tokens: Int64, locale: Locale = L10n.locale) -> String {
        let style = Decimal.FormatStyle.number.locale(locale).precision(.fractionLength(2))
        if tokens > 0 && tokens < 10_000 {
            return "<" + (Decimal(1) / 100).formatted(style) + " M"
        }
        // Two-decimal M would round to 1,000.00 here; promote the unit too.
        if tokens >= 999_995_000 {
            return (Decimal(tokens) / 1_000_000_000).formatted(style) + " B"
        }
        return (Decimal(tokens) / 1_000_000).formatted(style) + " M"
    }
}

public struct AntigravityTokenSnapshot: Equatable, Sendable {
    public let models: [AntigravityTokenModel]
    public let files: Int
    public let pendingFiles: Int
    public let unavailableFiles: Int
    public let skippedRecords: Int
    public let limited: Bool
    public let checkedAt: Date
    public let rowsRead: Int
    public let bytesRead: Int
    public let stepRowsRead: Int
    public let dailyBuckets: [DailyUsageBucket] // Same cache-inclusive total, for reliably dated records only.
    public let undatedGenerations: Int
    public var processed: Int64 { models.reduce(0) { $0 + $1.processed } }
    public var input: Int64 { models.reduce(0) { $0 + $1.input } }
    public var output: Int64 { models.reduce(0) { $0 + $1.output } }
    public var cacheRead: Int64 { models.reduce(0) { $0 + $1.cacheRead } }
    public var total: Int64 { models.reduce(0) { $0 + $1.total } }
    public var generations: Int { models.reduce(0) { $0 + $1.generations } }
    public var isPartial: Bool {
        pendingFiles > 0 || unavailableFiles > 0 || skippedRecords > 0 || limited
    }
    public var isCalendarPartial: Bool { isPartial || undatedGenerations > 0 }

    public init(models: [AntigravityTokenModel], files: Int, pendingFiles: Int,
                unavailableFiles: Int, skippedRecords: Int, limited: Bool,
                checkedAt: Date, rowsRead: Int, bytesRead: Int, stepRowsRead: Int = 0,
                dailyBuckets: [DailyUsageBucket] = [], undatedGenerations: Int? = nil) {
        self.models = models; self.files = files; self.pendingFiles = pendingFiles
        self.unavailableFiles = unavailableFiles; self.skippedRecords = skippedRecords
        self.limited = limited; self.checkedAt = checkedAt
        self.rowsRead = rowsRead; self.bytesRead = bytesRead; self.stepRowsRead = stepRowsRead
        self.dailyBuckets = dailyBuckets
        self.undatedGenerations = undatedGenerations ?? models.reduce(0) { $0 + $1.generations }
    }

    /// Gregorian days in the display time zone. Unknown history must not turn
    /// into zeros, and today is the observation day, never a backfill date.
    public func activityWeeks(count: Int = 18, calendar: Calendar = .current) -> [AntigravityTokenWeek] {
        guard count > 0, count <= 53 else { return [] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = calendar.timeZone; cal.firstWeekday = 2
        let formatter = Self.dayFormatter(timeZone: cal.timeZone)
        let today = formatter.string(from: checkedAt)
        let buckets = Dictionary(dailyBuckets.map { ($0.startDate, $0.tokens) }, uniquingKeysWith: { $0 + $1 })
        guard let thisMonday = cal.dateInterval(of: .weekOfYear, for: checkedAt)?.start,
              let firstMonday = cal.date(byAdding: .weekOfYear, value: -(count - 1), to: thisMonday) else { return [] }
        return (0..<count).map { week in
            let days = (0..<7).compactMap { offset -> AntigravityTokenDay? in
                guard let date = cal.date(byAdding: .day, value: week * 7 + offset, to: firstMonday) else { return nil }
                let key = formatter.string(from: date)
                let future = key > today
                let tokens = future ? nil : (buckets[key] ?? (isCalendarPartial ? nil : 0))
                return .init(date: date, id: key, tokens: tokens, isFuture: future,
                             isToday: key == today, isPartial: isCalendarPartial)
            }
            return AntigravityTokenWeek(id: week, days: days)
        }
    }

    static func dayFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    public static let preview = AntigravityTokenSnapshot(
        models: [
            .init(id: "Gemini", input: 2_800_000, output: 640_000, cacheRead: 9_200_000, generations: 260),
            .init(id: "Claude", input: 480_000, output: 120_000, cacheRead: 1_100_000, generations: 40)
        ], files: 5, pendingFiles: 0, unavailableFiles: 0, skippedRecords: 0,
        limited: false, checkedAt: Date(), rowsRead: 0, bytesRead: 0,
        dailyBuckets: previewBuckets(total: 14_340_000), undatedGenerations: 0
    )

    /// Synthetic UI-only fixture; never mixed with local cached records.
    public static func previewBuckets(total: Int64) -> [DailyUsageBucket] {
        let cal = Calendar(identifier: .gregorian)
        let formatter = dayFormatter(timeZone: cal.timeZone)
        let offsets = (0..<118).filter { $0 % 5 != 2 }
        let weights = offsets.map { Int64($0 * 17 % 13 + 1) }
        let sum = weights.reduce(0, +)
        var remaining = total
        return offsets.enumerated().compactMap { index, offset in
            guard let date = cal.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            let tokens = index == offsets.count - 1 ? remaining : total * weights[index] / sum
            remaining -= tokens
            return DailyUsageBucket(startDate: formatter.string(from: date), tokens: tokens)
        }
    }
}

public struct AntigravityTokenDay: Identifiable, Equatable, Sendable {
    public let date: Date
    public let id: String
    public let tokens: Int64?
    public let isFuture: Bool
    public let isToday: Bool
    public let isPartial: Bool
}

public struct AntigravityTokenWeek: Identifiable, Equatable, Sendable {
    public let id: Int
    public let days: [AntigravityTokenDay]
}

struct AntigravityTokenRecord: Equatable {
    let responseKey: String
    let model: String
    let input: Int64
    let output: Int64
    let cacheRead: Int64
    // Used only during the bounded read, never persisted as raw identifiers.
    let firstStepIndex: Int64?
    let executionKey: String?
}

enum AntigravityTokenDecodeError: Error { case malformed, unsupported }

/// Tiny bounded wire reader. Only known numeric usage fields are interpreted;
/// unknown fields (including any text payloads) are skipped, never decoded.
enum AntigravityTokenDecoder {
    static let maxBlobBytes = 1_048_576
    static let maxStepBlobBytes = 4096
    private static let maxCount: UInt64 = 1_000_000_000_000

    static func decode(_ data: Data) throws -> AntigravityTokenRecord {
        guard !data.isEmpty, data.count <= maxBlobBytes else { throw AntigravityTokenDecodeError.malformed }
        let root = try Wire(data)
        let chat = try Wire(root.bytes(1))
        let usage = try Wire(chat.bytes(4))
        let output = try usage.count(3, limit: maxCount, required: true)
        let thinking = try usage.count(9, limit: maxCount)
        let responseOutput = try usage.count(10, limit: maxCount)
        guard output == responseOutput + thinking else { throw AntigravityTokenDecodeError.unsupported }
        // Installed IDE ModelUsageStats descriptor: #1 is a model enum, NOT tokens.
        let input = try usage.count(2, limit: maxCount)
        let cache = try usage.count(5, limit: maxCount)
        let response = try usage.bytes(11)
        guard !response.isEmpty, response.count <= 512, input + output + cache > 0 else {
            throw AntigravityTokenDecodeError.unsupported
        }
        // Only a model family is retained. Raw labels, response IDs, titles and
        // workspace paths must not reach the cache, logs or UI.
        let labelData = (try? chat.bytes(21)) ?? Data()
        let modelData = (try? chat.bytes(19)) ?? Data()
        guard labelData.count <= 256, modelData.count <= 256 else { throw AntigravityTokenDecodeError.malformed }
        let label = (String(data: labelData, encoding: .utf8) ?? "").lowercased()
        let model = (String(data: modelData, encoding: .utf8) ?? "").lowercased()
        let families = Set([label, model].compactMap { value -> String? in
            if value.contains("gemini") { return "Gemini" }
            if value.contains("claude") { return "Claude" }
            if value.contains("gpt") { return "GPT" }
            return nil
        })
        let execution = (try? root.bytes(4)) ?? Data()
        return AntigravityTokenRecord(
            responseKey: digest(response), model: families.count == 1 ? families.first! : "Other",
            input: Int64(input), output: Int64(output), cacheRead: Int64(cache),
            firstStepIndex: try? root.firstStepIndex(),
            executionKey: !execution.isEmpty && execution.count <= 512 ? digest(execution) : nil
        )
    }

    /// CortexStepMetadata.created_at is a declared protobuf Timestamp. The
    /// association must match BOTH response and execution, not merely row order.
    /// ChatStartMetadata #10 is context-window metadata on IDE 2.12.2, not time.
    static func stepCreatedAt(_ data: Data, for record: AntigravityTokenRecord, now: Date) -> Int64? {
        guard !data.isEmpty, data.count <= maxStepBlobBytes, let executionKey = record.executionKey else { return nil }
        do {
            let step = try Wire(data)
            let execution = try step.bytes(12)
            let usage = try Wire(step.bytes(9))
            let response = try usage.bytes(11)
            guard execution.count <= 512, response.count <= 512,
                  digest(execution) == executionKey, digest(response) == record.responseKey else { return nil }
            let timestamp = try Wire(step.bytes(1))
            let seconds = try timestamp.count(1, limit: UInt64(max(0, now.timeIntervalSince1970 + 300)), required: true)
            let nanos = try timestamp.count(2, limit: 999_999_999)
            guard seconds >= 1_577_836_800 else { return nil } // Reject sentinels and non-event timestamps.
            return Int64(seconds * 1000 + nanos / 1_000_000)
        } catch { return nil }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Wire {
        enum Value { case number(UInt64), range(Range<Int>), skipped }
        let data: Data
        var fields: [Int: Value] = [:]

        init(_ data: Data) throws {
            self.data = data
            let bytes = [UInt8](data)
            var offset = 0
            func varint() throws -> UInt64 {
                var value: UInt64 = 0
                for shift in stride(from: 0, through: 63, by: 7) {
                    guard offset < bytes.count else { throw AntigravityTokenDecodeError.malformed }
                    let byte = bytes[offset]; offset += 1
                    guard shift != 63 || byte <= 1 else { throw AntigravityTokenDecodeError.malformed }
                    value |= UInt64(byte & 127) << shift
                    if byte & 128 == 0 { return value }
                }
                throw AntigravityTokenDecodeError.malformed
            }
            var fieldCount = 0
            while offset < bytes.count {
                fieldCount += 1
                guard fieldCount <= 4096 else { throw AntigravityTokenDecodeError.malformed }
                let tag = try varint()
                guard tag >> 3 > 0, tag >> 3 <= 536_870_911 else { throw AntigravityTokenDecodeError.malformed }
                let field = Int(tag >> 3)
                let value: Value
                switch tag & 7 {
                case 0: value = .number(try varint())
                case 2:
                    let size = try varint()
                    guard size <= UInt64(bytes.count - offset) else { throw AntigravityTokenDecodeError.malformed }
                    value = .range(offset..<(offset + Int(size)))
                    offset += Int(size)
                case 1, 5:
                    let size = tag & 7 == 1 ? 8 : 4
                    guard size <= bytes.count - offset else { throw AntigravityTokenDecodeError.malformed }
                    offset += size; value = .skipped
                default: throw AntigravityTokenDecodeError.malformed
                }
                // Repeated unknown fields are legal; consumed fields must be singular.
                if fields[field] != nil { fields[field] = .skipped } else { fields[field] = value }
            }
        }

        func bytes(_ field: Int) throws -> Data {
            guard case let .range(range) = fields[field] else { throw AntigravityTokenDecodeError.unsupported }
            return data.subdata(in: range)
        }

        func count(_ field: Int, limit: UInt64, required: Bool = false) throws -> UInt64 {
            if fields[field] == nil, !required { return 0 }
            guard case let .number(value) = fields[field], value <= limit else {
                throw AntigravityTokenDecodeError.unsupported
            }
            return value
        }

        func firstStepIndex() throws -> Int64 {
            if case let .number(value) = fields[2], value <= UInt32.max { return Int64(value) }
            let packed = [UInt8](try bytes(2))
            guard !packed.isEmpty, packed.count <= 160 else { throw AntigravityTokenDecodeError.unsupported }
            var indices: [UInt64] = [], offset = 0
            while offset < packed.count {
                guard indices.count < 32 else { throw AntigravityTokenDecodeError.unsupported }
                var value: UInt64 = 0, ended = false
                for shift in stride(from: 0, through: 28, by: 7) {
                    guard offset < packed.count else { throw AntigravityTokenDecodeError.malformed }
                    let byte = packed[offset]; offset += 1
                    value |= UInt64(byte & 127) << shift
                    if byte & 128 == 0 { ended = true; break }
                }
                guard ended, value <= UInt32.max else { throw AntigravityTokenDecodeError.malformed }
                indices.append(value)
            }
            return Int64(indices[0])
        }
    }
}
