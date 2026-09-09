import Foundation
import Testing
@testable import QuotAICore

private func encodedVarint(_ value: UInt64) -> Data {
    var number = value, result = Data()
    repeat {
        let byte = UInt8(number & 127); number >>= 7
        result.append(number > 0 ? byte | 128 : byte)
    } while number > 0
    return result
}
private func numeric(_ field: Int, _ value: UInt64) -> Data {
    encodedVarint(UInt64(field << 3)) + encodedVarint(value)
}
private func message(_ field: Int, _ value: Data) -> Data {
    encodedVarint(UInt64(field << 3 | 2)) + encodedVarint(UInt64(value.count)) + value
}
private func tokenBlob(response: String = "response-1", model: String = "Gemini", output: UInt64 = 13) -> Data {
    let usage = numeric(1, 11) + numeric(2, 22) + numeric(3, output)
        + numeric(5, 55) + numeric(9, 9) + numeric(10, 4) + message(11, Data(response.utf8))
    return message(1, message(4, usage) + message(21, Data(model.utf8)))
}

private func linkedTokenBlob(response: String = "response-1", step: UInt64 = 0, execution: String = "execution-test") -> Data {
    tokenBlob(response: response) + message(2, encodedVarint(step)) + message(4, Data(execution.utf8))
}

private func stepBlob(seconds: UInt64, nanos: UInt64 = 0, response: String = "response-1", execution: String = "execution-test") -> Data {
    message(1, numeric(1, seconds) + numeric(2, nanos))
        + message(9, message(11, Data(response.utf8))) + message(12, Data(execution.utf8))
}

private final class TokenFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("quotai-token-test-" + UUID().uuidString)
    var directory: URL { root.appendingPathComponent("conversations") }
    var cache: URL { root.appendingPathComponent("cache/usage.sqlite") }
    init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func database() throws -> (URL, TokenUsageDatabase) {
        let url = directory.appendingPathComponent(UUID().uuidString + ".db")
        let db = try TokenUsageDatabase(path: url.path, readOnly: false)
        try db.run("PRAGMA user_version=1")
        try db.run("CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY, data BLOB, size INTEGER)")
        return (url, db)
    }
    func put(_ db: TokenUsageDatabase, index: Int, blob: Data) throws {
        let hex = blob.map { String(format: "%02x", $0) }.joined()
        try db.run("INSERT OR REPLACE INTO gen_metadata VALUES(\(index),X'\(hex)',\(blob.count))")
    }
    func putStep(_ db: TokenUsageDatabase, index: Int, blob: Data) throws {
        try db.run("CREATE TABLE IF NOT EXISTS steps(idx INTEGER PRIMARY KEY, metadata BLOB, step_payload BLOB)")
        let hex = blob.map { String(format: "%02x", $0) }.joined()
        // A separate large body must not be part of the reader's byte budget.
        try db.run("INSERT OR REPLACE INTO steps VALUES(\(index),X'\(hex)',zeroblob(1000000))")
    }
    func reader(rows: Int = 100, bytes: Int = 100_000, running: Bool = false) -> AntigravityTokenReader {
        AntigravityTokenReader(directory: directory, cacheURL: cache,
            budget: .init(rows: rows, bytes: bytes, files: 10, seconds: 2), runtimeIsRunning: { running })
    }
}

@Test("AG token decoder uses separate input/output/cache fields and hashes response IDs")
func agTokenDecoder() throws {
    let record = try AntigravityTokenDecoder.decode(tokenBlob())
    #expect(record.input == 22) // #1 is a model enum, never input tokens.
    #expect(record.output == 13)
    #expect(record.cacheRead == 55)
    #expect(record.model == "Gemini")
    #expect(record.responseKey.count == 64)
    #expect(!record.responseKey.contains("response"))
    #expect(throws: (any Error).self) { try AntigravityTokenDecoder.decode(tokenBlob(output: 99)) }
    #expect(throws: (any Error).self) { try AntigravityTokenDecoder.decode(Data([0xff, 0xff])) }
    #expect(throws: (any Error).self) { try AntigravityTokenDecoder.decode(tokenBlob(response: "")) }
    #expect(try AntigravityTokenDecoder.decode(tokenBlob(model: "unrecognized-private-label")).model == "Other")
}

@Test("AG token reader is bounded, resumes after restart, and skips unchanged databases")
func agTokenIncrementalRead() async throws {
    let fixture = try TokenFixture()
    let (_, db) = try fixture.database()
    for index in 0..<5 { try fixture.put(db, index: index, blob: tokenBlob(response: "r\(index)")) }
    let first = try await fixture.reader(rows: 2).read()
    #expect(first.generations == 2)
    #expect(first.pendingFiles == 1)
    #expect(first.rowsRead == 2)
    let second = try await fixture.reader(rows: 2).read()
    #expect(second.generations == 4)
    let reader = fixture.reader(rows: 2)
    let third = try await reader.read()
    #expect(third.generations == 5)
    #expect(third.processed == 175)
    #expect(third.cacheRead == 275)
    #expect(third.pendingFiles == 0)
    let unchanged = try await reader.read()
    #expect(unchanged.rowsRead == 0)
    #expect(unchanged.bytesRead == 0)
    #expect(unchanged.processed == third.processed)
}

@Test("AG token cache reconciles in-place updates, deleted rows and removed files")
func agTokenReconciliation() async throws {
    let fixture = try TokenFixture()
    let (url, db) = try fixture.database()
    for index in 0..<3 { try fixture.put(db, index: index, blob: tokenBlob(response: "r\(index)")) }
    let reader = fixture.reader()
    #expect(try await reader.read().generations == 3)
    try fixture.put(db, index: 0, blob: tokenBlob(response: "r0", model: "Claude"))
    try db.run("DELETE FROM gen_metadata WHERE idx=2")
    let changed = try await reader.read()
    #expect(changed.generations == 2)
    #expect(changed.models.contains { $0.id == "Claude" && $0.generations == 1 })
    try FileManager.default.removeItem(at: url)
    #expect(try await reader.read().generations == 0)
}

@Test("AG token reader deduplicates forked responses and excludes inconsistent copies")
func agTokenDeduplication() async throws {
    let fixture = try TokenFixture()
    let (_, first) = try fixture.database(), (_, second) = try fixture.database()
    try fixture.put(first, index: 0, blob: tokenBlob())
    try fixture.put(second, index: 8, blob: tokenBlob())
    let reader = fixture.reader()
    #expect(try await reader.read().generations == 1)
    try fixture.put(second, index: 8, blob: tokenBlob(model: "Claude"))
    let conflict = try await reader.read()
    #expect(conflict.generations == 0)
    #expect(conflict.skippedRecords == 1)
    #expect(conflict.isPartial)
}

@Test("AG token reader consumes committed WAL data without blocking an open writer")
func agTokenWALRead() async throws {
    let fixture = try TokenFixture()
    let (_, db) = try fixture.database()
    try db.run("PRAGMA journal_mode=WAL")
    try fixture.put(db, index: 0, blob: tokenBlob())
    try db.run("BEGIN IMMEDIATE")
    try fixture.put(db, index: 1, blob: tokenBlob(response: "pending"))
    let reader = fixture.reader(running: true)
    let snapshot = try await reader.read()
    #expect(snapshot.generations == 1)
    #expect(snapshot.unavailableFiles == 0)
    try db.run("COMMIT")
    #expect(try await reader.read().generations == 2)
}

@Test("AG reader fails closed for schema drift, oversized blobs and missing dedup IDs")
func agTokenInvalidRecords() async throws {
    let fixture = try TokenFixture()
    let (_, db) = try fixture.database()
    try fixture.put(db, index: 0, blob: tokenBlob(response: ""))
    try fixture.put(db, index: 1, blob: Data(repeating: 1, count: 1024))
    try fixture.put(db, index: 2, blob: tokenBlob())
    let snapshot = try await fixture.reader(bytes: 512).read()
    #expect(snapshot.skippedRecords == 2)
    #expect(snapshot.generations == 1)
    #expect(snapshot.bytesRead <= 512)
    try db.run("PRAGMA user_version=99")
    let changed = try await fixture.reader().read()
    #expect(changed.unavailableFiles == 1)
    #expect(changed.isPartial)
}

@Test("AG cache never stores raw response identifiers, model labels or source paths")
func agTokenCachePrivacy() async throws {
    let fixture = try TokenFixture()
    let (_, db) = try fixture.database()
    try fixture.put(db, index: 0, blob: tokenBlob(response: "private-response-marker", model: "private-model-marker"))
    _ = try await fixture.reader().read()
    let cache = try Data(contentsOf: fixture.cache)
    for secret in ["private-response-marker", "private-model-marker", fixture.directory.path] {
        #expect(cache.range(of: Data(secret.utf8)) == nil)
    }
}

@Test("AG reader detects edits between slices and completes a reconciliation pass")
func agTokenChangedBetweenSlices() async throws {
    let fixture = try TokenFixture()
    let (_, db) = try fixture.database()
    for index in 0..<3 { try fixture.put(db, index: index, blob: tokenBlob(response: "r\(index)")) }
    let reader = fixture.reader(rows: 1)
    #expect(try await reader.read().generations == 1)
    try fixture.put(db, index: 0, blob: tokenBlob(response: "r0", model: "Claude"))
    var final: AntigravityTokenSnapshot?
    for _ in 0..<10 {
        final = try await reader.read()
        if final?.pendingFiles == 0 { break }
    }
    #expect(final?.pendingFiles == 0)
    #expect(final?.generations == 3)
    #expect(final?.models.first(where: { $0.id == "Claude" })?.generations == 1)
}

@Test("AG reader refuses immutable access while a runtime may be running")
func agTokenOfflineWALSafety() async throws {
    let fixture = try TokenFixture()
    // Build a checkpointed, closed WAL-mode fixture without sidecars. Closing
    // the connection alone does not guarantee this filesystem state here.
    var created: (URL, TokenUsageDatabase)? = try fixture.database()
    let url = created!.0
    try created!.1.run("PRAGMA journal_mode=WAL")
    try fixture.put(created!.1, index: 0, blob: tokenBlob())
    try #require(try created!.1.integer("PRAGMA wal_checkpoint(TRUNCATE)") == 0)
    created = nil
    for suffix in ["-wal", "-shm"] {
        let sidecar = URL(fileURLWithPath: url.path + suffix)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.removeItem(at: sidecar)
        }
    }
    #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
    let before = try Data(contentsOf: url)
    let unavailable = try await fixture.reader(running: true).read()
    #expect(unavailable.generations == 0)
    #expect(unavailable.unavailableFiles == 1)
    #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
    #expect(try await fixture.reader(running: false).read().generations == 1)
    #expect(try Data(contentsOf: url) == before)
}

@Test("AG reader rejects a non-indexed metadata schema instead of doing a full scan")
func agTokenSchemaSafety() async throws {
    let fixture = try TokenFixture()
    let (_, db) = try fixture.database()
    try db.run("DROP TABLE gen_metadata")
    try db.run("CREATE TABLE gen_metadata(idx INTEGER, data BLOB)")
    let snapshot = try await fixture.reader().read()
    #expect(snapshot.unavailableFiles == 1)
    #expect(snapshot.rowsRead == 0)
}

@Test("AG dates require a declared timestamp and matching response and execution")
func agStepDateValidation() throws {
    let seconds: UInt64 = 1_777_766_400 // A fixed past timestamp, not file/refresh time.
    let now = Date(timeIntervalSince1970: Double(seconds + 86400))
    let record = try AntigravityTokenDecoder.decode(linkedTokenBlob(step: 3))
    #expect(record.firstStepIndex == 3)
    #expect(AntigravityTokenDecoder.stepCreatedAt(stepBlob(seconds: seconds, nanos: 123_000_000), for: record, now: now) == Int64(seconds * 1000 + 123))
    for blob in [stepBlob(seconds: seconds, response: "different-response"),
                 stepBlob(seconds: seconds, execution: "different-execution"),
                 stepBlob(seconds: seconds, nanos: 1_000_000_000),
                 stepBlob(seconds: 0), stepBlob(seconds: seconds + 90_000),
                 message(1, Data(repeating: 0, count: 8)),
                 Data(repeating: 0, count: 4097)] {
        #expect(AntigravityTokenDecoder.stepCreatedAt(blob, for: record, now: now) == nil)
    }
    let noAssociation = try AntigravityTokenDecoder.decode(tokenBlob())
    #expect(AntigravityTokenDecoder.stepCreatedAt(stepBlob(seconds: seconds), for: noAssociation, now: now) == nil)
    let invalidPacked = tokenBlob() + message(2, Data([0x80]))
    #expect(try AntigravityTokenDecoder.decode(invalidPacked).firstStepIndex == nil)
    let oversizedReferences = tokenBlob() + message(2, Data(repeating: 0, count: 33))
    #expect(try AntigravityTokenDecoder.decode(oversizedReferences).firstStepIndex == nil)
}

@Test("AG daily totals include cache hits, use linked dates, and preserve undated calls")
func agDailyAttribution() async throws {
    let fixture = try TokenFixture()
    let (_, db) = try fixture.database()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let midnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 4)))
    let seconds = UInt64(midnight.timeIntervalSince1970)
    try fixture.put(db, index: 0, blob: linkedTokenBlob(response: "before", step: 3))
    try fixture.putStep(db, index: 3, blob: stepBlob(seconds: seconds - 1, response: "before"))
    try fixture.put(db, index: 1, blob: linkedTokenBlob(response: "after", step: 8))
    try fixture.putStep(db, index: 8, blob: stepBlob(seconds: seconds + 1, response: "after"))
    try fixture.put(db, index: 2, blob: tokenBlob(response: "undated"))
    let reader = fixture.reader()
    let snapshot = try await reader.read()
    #expect(snapshot.dailyBuckets == [.init(startDate: "2026-05-03", tokens: 90), .init(startDate: "2026-05-04", tokens: 90)])
    #expect(snapshot.processed == 105 && snapshot.cacheRead == 165)
    #expect(snapshot.total == 270 && snapshot.models.reduce(0) { $0 + $1.total } == 270)
    #expect(snapshot.undatedGenerations == 1 && snapshot.isCalendarPartial && !snapshot.isPartial)
    #expect(snapshot.rowsRead == 5 && snapshot.stepRowsRead == 2)
    #expect(snapshot.bytesRead < 1024) // Million-byte step_payload was never fetched.
    let unchanged = try await reader.read()
    #expect(unchanged.rowsRead == 0 && unchanged.bytesRead == 0)
    #expect(unchanged.dailyBuckets == snapshot.dailyBuckets)
    // Step edits alone invalidate the source fingerprint; no refresh-date backfill.
    try fixture.putStep(db, index: 8, blob: stepBlob(seconds: seconds - 2, response: "after"))
    #expect(try await reader.read().dailyBuckets == [.init(startDate: "2026-05-03", tokens: 180)])
    try db.run("DELETE FROM steps WHERE idx=8")
    #expect(try await reader.read().undatedGenerations == 2)
}

@Test("AG date lookups share row/byte limits and resume without losing dates")
func agDateReadBudget() async throws {
    let fixture = try TokenFixture()
    let (_, db) = try fixture.database()
    for index in 0..<4 {
        try fixture.put(db, index: index, blob: linkedTokenBlob(response: "r\(index)", step: UInt64(index)))
        try fixture.putStep(db, index: index, blob: stepBlob(seconds: 1_777_766_400, response: "r\(index)"))
    }
    let reader = fixture.reader(rows: 3, bytes: 200)
    var final: AntigravityTokenSnapshot?
    for _ in 0..<12 {
        final = try await reader.read()
        #expect(final!.rowsRead <= 3 && final!.bytesRead <= 200)
        #expect(final!.undatedGenerations == 0)
        if final!.pendingFiles == 0 { break }
    }
    #expect(final?.pendingFiles == 0 && final?.generations == 4)
    #expect(final?.dailyBuckets.reduce(0) { $0 + $1.tokens } == 360)
}

@Test("AG timestamp conflicts keep counts but exclude ambiguous dates")
func agDateDeduplication() async throws {
    let fixture = try TokenFixture()
    let (_, a) = try fixture.database(), (_, b) = try fixture.database()
    try fixture.put(a, index: 0, blob: linkedTokenBlob())
    try fixture.put(b, index: 0, blob: linkedTokenBlob())
    try fixture.putStep(a, index: 0, blob: stepBlob(seconds: 1_777_766_400))
    try fixture.putStep(b, index: 0, blob: stepBlob(seconds: 1_777_766_400))
    let reader = fixture.reader()
    let same = try await reader.read()
    #expect(same.generations == 1 && same.undatedGenerations == 0)
    #expect(same.dailyBuckets.reduce(0) { $0 + $1.tokens } == 90)
    try fixture.putStep(b, index: 0, blob: stepBlob(seconds: 1_777_766_400 + 86400))
    let conflict = try await reader.read()
    #expect(conflict.generations == 1 && conflict.processed == 35)
    #expect(conflict.total == 90)
    #expect(conflict.dailyBuckets.isEmpty && conflict.undatedGenerations == 1)
}

@Test("AG optional date schema fails closed without discarding valid token counts")
func agOptionalDateSchema() async throws {
    let fixture = try TokenFixture()
    let (_, db) = try fixture.database()
    try fixture.put(db, index: 0, blob: linkedTokenBlob())
    try db.run("CREATE TABLE steps(idx INTEGER, metadata BLOB)")
    let missingIndex = try await fixture.reader().read()
    #expect(missingIndex.generations == 1 && missingIndex.undatedGenerations == 1)
    #expect(missingIndex.stepRowsRead == 0 && missingIndex.unavailableFiles == 0)
    let cache = try TokenUsageDatabase(path: fixture.cache.path, readOnly: true)
    #expect(try cache.integer("PRAGMA user_version") == 2)
    let data = try Data(contentsOf: fixture.cache)
    #expect(data.range(of: Data("execution-test".utf8)) == nil)
}

@Test("AG rejects stale v1 cache rather than displaying inflated input counts")
func agStaleCache() async throws {
    let fixture = try TokenFixture()
    try FileManager.default.createDirectory(at: fixture.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
    let old = try TokenUsageDatabase(path: fixture.cache.path, readOnly: false)
    try old.run("PRAGMA user_version=1")
    do {
        _ = try await fixture.reader().read()
        Issue.record("v1 cache should not be read as v2")
    } catch { #expect(try old.integer("PRAGMA user_version") == 1) }
}

@Test("AG calendar distinguishes unknown/partial/zero, uses Gregorian days and survives DST")
func agCalendarSemantics() throws {
    var calendar = Calendar(identifier: .buddhist)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let today = try #require(ISO8601DateFormatter().date(from: "2026-03-10T12:00:00Z"))
    func snapshot(pending: Int = 0, undated: Int = 0) -> AntigravityTokenSnapshot {
        .init(models: [.init(id: "Gemini", input: 22, output: 13, cacheRead: 55, generations: 1)],
              files: 1, pendingFiles: pending, unavailableFiles: 0, skippedRecords: 0,
              limited: false, checkedAt: today, rowsRead: 0, bytesRead: 0,
              dailyBuckets: [.init(startDate: "2026-03-08", tokens: 90)], undatedGenerations: undated)
    }
    let days = snapshot().activityWeeks(calendar: calendar).flatMap(\.days)
    #expect(days.count == 126 && Set(days.map(\.id)).count == 126)
    #expect(days.first?.id == "2025-11-10" && days.last?.id == "2026-03-15")
    #expect(days.first { $0.id == "2026-03-08" }?.tokens == 90)
    #expect(days.first { $0.isToday }?.id == "2026-03-10")
    #expect(days.first { $0.id == "2026-03-09" }?.tokens == 0)
    #expect(days.filter(\.isFuture).allSatisfy { $0.tokens == nil })
    for partial in [snapshot(pending: 1), snapshot(undated: 1)] {
        let partialDays = partial.activityWeeks(calendar: calendar).flatMap(\.days)
        #expect(partialDays.first { $0.id == "2026-03-09" }?.tokens == nil)
        #expect(partialDays.first { $0.id == "2026-03-08" }?.tokens == 90)
        #expect(partialDays.allSatisfy { $0.isPartial })
    }
    #expect(snapshot().activityWeeks(count: 0).isEmpty)
}

@Test("AG uses fixed M units with honest small values and no K or B switching")
func agMillionUnits() {
    for language in ["en_US", "zh_CN"] {
        let locale = Locale(identifier: language)
        #expect(AntigravityTokenFormat.millions(0, locale: locale) == "0.00 M")
        #expect(AntigravityTokenFormat.millions(1, locale: locale) == "<0.01 M")
        #expect(AntigravityTokenFormat.millions(9_999, locale: locale) == "<0.01 M")
        #expect(AntigravityTokenFormat.millions(10_000, locale: locale) == "0.01 M")
        #expect(AntigravityTokenFormat.millions(105_800, locale: locale) == "0.11 M")
        #expect(AntigravityTokenFormat.millions(3_215_617, locale: locale) == "3.22 M")
        #expect(AntigravityTokenFormat.millions(1_100_000_000, locale: locale) == "1,100.00 M")
        #expect(AntigravityTokenFormat.millions(Int64.max, locale: locale) == "9,223,372,036,854.78 M")
    }
    // The shared Codex formatter is not changed by this AG-only preference.
    #expect(DailyUsageBucket.formatTokens(105_800).contains("K"))
}

@Test("AG total, model totals, breakdown and complete daily fixture reconcile including cache")
func agInclusiveTotal() {
    let snapshot = AntigravityTokenSnapshot.preview
    #expect(snapshot.input == 3_280_000 && snapshot.output == 760_000 && snapshot.cacheRead == 10_300_000)
    #expect(snapshot.total == snapshot.input + snapshot.output + snapshot.cacheRead)
    #expect(snapshot.total == 14_340_000)
    #expect(snapshot.models.map(\.total) == [12_640_000, 1_700_000])
    #expect(snapshot.dailyBuckets.reduce(0) { $0 + $1.tokens } == snapshot.total)
}

@Test("AG cache-only usage is counted once across duplicate sources and a retained v2 cache")
func agCacheOnlyTotal() async throws {
    let fixture = try TokenFixture()
    let (_, first) = try fixture.database(), (_, duplicate) = try fixture.database()
    let usage = numeric(2, 0) + numeric(3, 0) + numeric(5, 2_000_000)
        + numeric(9, 0) + numeric(10, 0) + message(11, Data("cache-only".utf8))
    let blob = message(1, message(4, usage) + message(21, Data("Gemini".utf8)))
        + message(2, encodedVarint(0)) + message(4, Data("execution-test".utf8))
    for db in [first, duplicate] {
        try fixture.put(db, index: 0, blob: blob)
        try fixture.putStep(db, index: 0, blob: stepBlob(seconds: 1_777_766_400, response: "cache-only"))
    }
    let initial = try await fixture.reader().read()
    #expect(initial.generations == 1 && initial.processed == 0 && initial.total == 2_000_000)
    #expect(initial.dailyBuckets.reduce(0) { $0 + $1.tokens } == initial.total)
    let cached = try await fixture.reader().read()
    #expect(cached.total == initial.total && cached.dailyBuckets == initial.dailyBuckets)
    #expect(cached.rowsRead == 0 && cached.stepRowsRead == 0 && cached.bytesRead == 0)
    let cache = try TokenUsageDatabase(path: fixture.cache.path, readOnly: true)
    #expect(try cache.integer("PRAGMA user_version") == 2)
}
