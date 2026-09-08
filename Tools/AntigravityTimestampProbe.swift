import Foundation

/// Bounded, read-only metadata/schema diagnostic. No model calls, no transcript
/// table payloads, no retained identifiers, headers or raw metadata output.
@main
struct AntigravityTimestampProbe {
    static func main() throws {
        guard !AntigravityTokenReader.hasRuntime() else { throw TokenUsageReadError.unavailable }
        let fm = FileManager.default
        let directory = fm.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity/conversations")
        let files = try fm.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey])
            .filter { $0.pathExtension == "db" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        guard !files.isEmpty else { throw TokenUsageReadError.unavailable }
        let picks = Set([0, files.count / 3, files.count * 2 / 3, files.count - 1]).sorted()
        var totalBytes = 0
        for (sample, pick) in picks.enumerated() {
            let url = files[pick]
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  !fm.fileExists(atPath: url.path + "-wal"), !fm.fileExists(atPath: url.path + "-shm") else { continue }
            let before = try fm.attributesOfItem(atPath: url.path)
            let db = try TokenUsageDatabase(path: url.absoluteString + "?mode=ro&immutable=1", readOnly: true)
            db.limitWork(until: ProcessInfo.processInfo.systemUptime + 0.1)
            if sample == 0 {
                let schema = try db.prepare("SELECT name,sql FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'")
                while try schema.next() { print("schema \(schema.text(0)): \(schema.text(1))") }
            }
            let maxIndex = try db.integer("SELECT max(idx) FROM gen_metadata")
            var visited = Set<Int64>(), rows = 0, startTimes = 0, headerDates = 0
            var modelMatches = 0, contextMessages = 0, contextShapes = Set<String>()
            var rootShapes = Set<String>(), chatShapes = Set<String>(), startShapes = Set<String>()
            var days = Set<String>()
            var stepsRead = 0, datedGenerations = 0, executionMatches = 0, responseMatches = 0
            var firstStepResponseMatches = 0
            var dated: [(Int64, Date)] = []
            let stepQuery = try db.prepare("SELECT CASE WHEN length(metadata)<=4096 THEN metadata END FROM steps WHERE idx=?")
            for cursor in [-1, maxIndex / 2, max(-1, maxIndex - 8)] {
                let query = try db.prepare("SELECT idx,CASE WHEN length(data)<=16384 THEN data END FROM gen_metadata WHERE idx>? ORDER BY idx LIMIT 8")
                query.bind(cursor, at: 1)
                while try query.next() {
                    guard visited.insert(query.int(0)).inserted, let data = query.blob(1), totalBytes + data.count <= 512 * 1024 else { continue }
                    totalBytes += data.count; rows += 1
                    let root = try ProbeWire(data), chat = try ProbeWire(root.bytes(1)), usage = try ProbeWire(chat.bytes(4))
                    rootShapes.insert(root.shape); chatShapes.insert(chat.shape)
                    if usage.number(1) == chat.number(3), usage.number(1) != nil { modelMatches += 1 }
                    if let start = try? ProbeWire(chat.bytes(9)) {
                        startShapes.insert(start.shape)
                        if let stamp = try? ProbeWire(start.bytes(4)), let date = stamp.timestamp {
                            startTimes += 1; days.insert(Self.day(date))
                        }
                        if let context = try? start.bytes(10) {
                            contextMessages += 1
                            if let fields = try? ProbeWire(context) { contextShapes.insert(fields.shape) }
                        }
                    }
                    for header in usage.repeatedBytes(8) {
                        guard let entry = try? ProbeWire(header),
                              let key = try? String(data: entry.bytes(1), encoding: .utf8), key.lowercased() == "date",
                              let value = try? String(data: entry.bytes(2), encoding: .utf8) else { continue }
                        let formatter = DateFormatter()
                        formatter.locale = Locale(identifier: "en_US_POSIX")
                        formatter.timeZone = TimeZone(secondsFromGMT: 0)
                        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                        if let date = formatter.date(from: value) { headerDates += 1; days.insert(Self.day(date)) }
                    }
                    var stepDates: [Date] = []
                    let linkedIndices = ((try? root.packedNumbers(2)) ?? []).sorted()
                    for index in linkedIndices {
                        guard stepsRead < 256 else { break }
                        stepQuery.reset(); stepQuery.bind(Int64(index), at: 1)
                        guard try stepQuery.next(), let metadata = stepQuery.blob(0), totalBytes + metadata.count <= 512 * 1024 else { continue }
                        totalBytes += metadata.count; stepsRead += 1
                        let step = try ProbeWire(metadata)
                        if let stamp = try? ProbeWire(step.bytes(1)), let date = stamp.timestamp { stepDates.append(date) }
                        if (try? step.bytes(12)) == (try? root.bytes(4)) { executionMatches += 1 }
                        if let stepUsage = try? ProbeWire(step.bytes(9)),
                           (try? stepUsage.bytes(11)) == (try? usage.bytes(11)) {
                            responseMatches += 1
                            if index == linkedIndices.first { firstStepResponseMatches += 1 }
                        }
                    }
                    if let first = stepDates.min() {
                        datedGenerations += 1; days.insert(Self.day(first)); dated.append((query.int(0), first))
                    }
                }
            }
            let after = try fm.attributesOfItem(atPath: url.path)
            guard !AntigravityTokenReader.hasRuntime(), !fm.fileExists(atPath: url.path + "-wal"),
                  before[.modificationDate] as? Date == after[.modificationDate] as? Date,
                  before[.size] as? Int == after[.size] as? Int else { throw TokenUsageReadError.unavailable }
            print("sample=\(sample + 1) rows=\(rows) explicitDates=\(startTimes) httpDates=\(headerDates) usageModelEqualsChatModel=\(modelMatches) contextMessages=\(contextMessages) distinctDateCount=\(days.count)")
            let ordered = dated.sorted { $0.0 < $1.0 }
            let inversions = zip(ordered, ordered.dropFirst()).filter { $0.1 > $1.1 }.count
            print("stepsRead=\(stepsRead) generationsWithStepDate=\(datedGenerations) matchingExecutionIDs=\(executionMatches) matchingResponseIDs=\(responseMatches) firstStepResponseMatches=\(firstStepResponseMatches) dateOrderInversions=\(inversions) context=\(contextShapes.sorted())")
        }
        print("totalMetadataBytes=\(totalBytes)")
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct ProbeWire {
    enum Value { case integer(UInt64), data(Data), other }
    var fields: [Int: [Value]] = [:]

    init(_ data: Data) throws {
        let bytes = [UInt8](data); var at = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard at < bytes.count else { throw TokenUsageReadError.schema }
                let byte = bytes[at]; at += 1
                guard shift < 63 || byte <= 1 else { throw TokenUsageReadError.schema }
                result |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return result }
            }
            throw TokenUsageReadError.schema
        }
        while at < bytes.count {
            let tag = try varint(); guard tag >> 3 > 0 else { throw TokenUsageReadError.schema }
            let value: Value
            switch tag & 7 {
            case 0: value = .integer(try varint())
            case 2:
                let size = try varint(); guard size <= bytes.count - at else { throw TokenUsageReadError.schema }
                value = .data(Data(bytes[at..<at + Int(size)])); at += Int(size)
            case 1, 5:
                let size = tag & 7 == 1 ? 8 : 4
                guard size <= bytes.count - at else { throw TokenUsageReadError.schema }
                value = .other; at += size
            default: throw TokenUsageReadError.schema
            }
            fields[Int(tag >> 3), default: []].append(value)
        }
    }
    var shape: String {
        fields.keys.sorted().map { key in
            let kind: String
            switch fields[key]!.first! {
            case .integer: kind = "varint"
            case .data(let data): kind = "bytes(\(data.count))"
            case .other: kind = "fixed"
            }
            return "\(key):\(kind)"
        }.joined(separator: ",")
    }
    func bytes(_ field: Int) throws -> Data {
        guard fields[field]?.count == 1, case let .data(data) = fields[field]?.first else { throw TokenUsageReadError.schema }
        return data
    }
    func repeatedBytes(_ field: Int) -> [Data] {
        fields[field, default: []].compactMap { if case let .data(value) = $0 { value } else { nil } }
    }
    func number(_ field: Int) -> UInt64? {
        guard fields[field]?.count == 1, case let .integer(value) = fields[field]?.first else { return nil }
        return value
    }
    func packedNumbers(_ field: Int) throws -> [UInt64] {
        var result: [UInt64] = []
        for value in fields[field, default: []] {
            switch value {
            case .integer(let number): result.append(number)
            case .data(let data):
                let bytes = [UInt8](data); var at = 0
                while at < bytes.count {
                    var number: UInt64 = 0, done = false
                    for shift in stride(from: 0, through: 63, by: 7) {
                        guard at < bytes.count else { throw TokenUsageReadError.schema }
                        let byte = bytes[at]; at += 1
                        number |= UInt64(byte & 127) << shift
                        if byte & 128 == 0 { done = true; break }
                    }
                    guard done, number <= UInt32.max, result.count < 32 else { throw TokenUsageReadError.schema }
                    result.append(number)
                }
            default: throw TokenUsageReadError.schema
            }
        }
        return result
    }
    var timestamp: Date? {
        guard let seconds = number(1), seconds >= 1_577_836_800, seconds <= UInt64(Date().timeIntervalSince1970 + 300),
              (number(2) ?? 0) < 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(number(2) ?? 0) / 1e9)
    }
}
