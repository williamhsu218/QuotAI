import Darwin
import Foundation

/// No timer, watcher, subprocess, network request or retained SQLite connection.
/// One bounded slice of work is performed only when explicitly requested.
actor AntigravityTokenReader {
    struct Budget: Sendable {
        var rows = 512
        var bytes = 768 * 1024
        var files = 4
        var seconds: TimeInterval = 0.08
    }
    private struct Source {
        var fingerprint: String
        var cursor: Int64
        var pass: Int64
        var complete: Bool
        var touched: Int64
    }
    private struct Row {
        let index: Int64
        let record: AntigravityTokenRecord?
        let occurredAt: Int64?
    }
    private struct Slice {
        let rows: [Row]
        let bytes: Int
        let ended: Bool
        let fingerprint: String
        let rowsRead: Int
        let stepRowsRead: Int
    }

    private let directory: URL
    private let cacheURL: URL
    private let budget: Budget
    private let runtimeIsRunning: @Sendable () -> Bool

    init(directory: URL? = nil, cacheURL: URL? = nil, budget: Budget = Budget(),
         runtimeIsRunning: @escaping @Sendable () -> Bool = { AntigravityTokenReader.hasRuntime() }) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
        self.cacheURL = cacheURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuotAI/AntigravityTokens/metadata-v2.sqlite")
        self.budget = budget
        self.runtimeIsRunning = runtimeIsRunning
    }

    func read() throws -> AntigravityTokenSnapshot {
        try Task.checkCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + budget.seconds
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TokenUsageReadError.unavailable
        }
        // A shallow, capped listing. Never walk brain/, logs or conversation bodies.
        var listingFailed = false
        guard let listing = fm.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles],
            errorHandler: { _, _ in listingFailed = true; return false }) else {
            throw TokenUsageReadError.unavailable
        }
        var files: [(key: String, url: URL, stamp: String)] = []
        var listingLimited = false
        var visited = 0
        for case let url as URL in listing {
            visited += 1
            if visited > 2048 || files.count >= 512 { listingLimited = true; break }
            guard url.pathExtension == "db", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let key = AntigravityTokenDecoder.digest(Data(url.standardizedFileURL.path.utf8))
            files.append((key, url, try fingerprint(url)))
        }
        guard !listingFailed else { throw TokenUsageReadError.unavailable }

        try fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let cache = try TokenUsageDatabase(path: cacheURL.path, readOnly: false)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        try configure(cache)
        var sources = try loadSources(cache)
        let keys = Set(files.map(\.key))
        if !listingLimited {
            for key in sources.keys.filter({ !keys.contains($0) }) {
                try removeSource(key, cache: cache)
                sources.removeValue(forKey: key)
            }
        }
        for file in files {
            if var source = sources[file.key] {
                if source.complete && source.fingerprint != file.stamp {
                    source.cursor = -1; source.pass += 1; source.complete = false
                    source.fingerprint = file.stamp
                    sources[file.key] = source
                    try saveSource(file.key, source, cache: cache)
                }
            } else {
                let source = Source(fingerprint: file.stamp, cursor: -1, pass: 1, complete: false, touched: 0)
                sources[file.key] = source
                try saveSource(file.key, source, cache: cache)
            }
        }
        // Fairness prevents one busy/unreadable conversation starving all others.
        let work = files.filter { sources[$0.key]?.complete == false }.sorted {
            let left = sources[$0.key]?.touched ?? 0, right = sources[$1.key]?.touched ?? 0
            return left == right ? $0.key < $1.key : left < right
        }
        var rowsRead = 0, stepRowsRead = 0, bytesRead = 0, attempted = 0, unavailable = 0
        let nextTouch = (sources.values.map(\.touched).max() ?? 0) + 1
        var limited = listingLimited
        let cachedRows = try cache.integer("SELECT count(*) FROM records")
        // Process discovery is needed only when a source will actually be read.
        let canUseImmutable = work.isEmpty ? false : !runtimeIsRunning()
        for file in work {
            try Task.checkCancellation()
            guard rowsRead < budget.rows, bytesRead < budget.bytes, attempted < budget.files,
                  ProcessInfo.processInfo.systemUptime < deadline, cachedRows + Int64(rowsRead) < 100_000 else {
                limited = true; break
            }
            attempted += 1
            var source = sources[file.key]!
            source.touched = nextTouch
            let originalSource = source
            do {
                let slice = try readSlice(file.url, after: source.cursor,
                    maxRows: min(budget.rows - rowsRead, Int(100_000 - cachedRows) - rowsRead),
                    maxBytes: budget.bytes - bytesRead,
                    deadline: deadline, allowImmutable: canUseImmutable)
                rowsRead += slice.rowsRead; stepRowsRead += slice.stepRowsRead; bytesRead += slice.bytes
                try cache.run("BEGIN IMMEDIATE")
                do {
                    let insert = try cache.prepare("""
                        INSERT OR REPLACE INTO records(source,idx,pass,response_key,model,input,output,cache_read,occurred_ms)
                        VALUES(?,?,?,?,?,?,?,?,?)
                        """)
                    for row in slice.rows {
                        insert.reset()
                        insert.bind(file.key, at: 1); insert.bind(row.index, at: 2)
                        insert.bind(source.pass, at: 3)
                        insert.bind(row.record?.responseKey ?? "", at: 4)
                        insert.bind(row.record?.model ?? "Other", at: 5)
                        insert.bind(row.record?.input ?? 0, at: 6)
                        insert.bind(row.record?.output ?? 0, at: 7)
                        insert.bind(row.record?.cacheRead ?? 0, at: 8)
                        if let occurredAt = row.occurredAt { insert.bind(occurredAt, at: 9) }
                        else { insert.bindNull(at: 9) }
                        _ = try insert.next()
                        source.cursor = row.index
                    }
                    if slice.ended {
                        // Reconcile rewinds and in-place edits, not just appended rows.
                        let prune = try cache.prepare("DELETE FROM records WHERE source=? AND pass<>?")
                        prune.bind(file.key, at: 1); prune.bind(source.pass, at: 2)
                        _ = try prune.next()
                        source.complete = source.fingerprint == slice.fingerprint
                        if !source.complete {
                            // A file changed between slices. Keep observed values but
                            // perform another bounded pass before claiming completeness.
                            source.cursor = -1; source.pass += 1; source.fingerprint = slice.fingerprint
                        }
                    }
                    try saveSource(file.key, source, cache: cache)
                    try cache.run("COMMIT")
                } catch {
                    try? cache.run("ROLLBACK")
                    throw error
                }
            } catch {
                unavailable += 1
                source = originalSource
                try saveSource(file.key, source, cache: cache)
            }
            sources[file.key] = source
        }
        return try snapshot(cache, files: files.count,
            pending: sources.values.filter { !$0.complete }.count,
            unavailable: unavailable, limited: limited, rows: rowsRead, bytes: bytesRead, stepRows: stepRowsRead)
    }

    private func readSlice(_ url: URL, after cursor: Int64, maxRows: Int, maxBytes: Int,
                           deadline: TimeInterval, allowImmutable: Bool) throws -> Slice {
        let before = try fingerprint(url)
        let fm = FileManager.default
        let wal = fm.fileExists(atPath: url.path + "-wal")
        let shm = fm.fileExists(atPath: url.path + "-shm")
        let header = try FileHandle(forReadingFrom: url)
        defer { try? header.close() }
        let bytes = try header.read(upToCount: 20) ?? Data()
        guard bytes.count == 20, bytes.prefix(16) == Data("SQLite format 3\0".utf8) else {
            throw TokenUsageReadError.schema
        }
        let walMode = bytes[18] == 2
        let immutable = walMode && !wal && !shm
        // Never pretend a live WAL database is immutable or create its sidecars.
        guard !walMode || (wal && shm) || (immutable && allowImmutable) else {
            throw TokenUsageReadError.unavailable
        }
        let path = immutable ? url.absoluteString + "?mode=ro&immutable=1" : url.path
        let database = try TokenUsageDatabase(path: path, readOnly: true)
        database.limitWork(until: deadline)
        guard try database.integer("PRAGMA user_version") == 1 else { throw TokenUsageReadError.schema }
        let kind = try database.prepare("SELECT type FROM sqlite_schema WHERE name='gen_metadata'")
        guard try kind.next(), kind.text(0) == "table" else { throw TokenUsageReadError.schema }
        let columns = try database.prepare("PRAGMA table_info(gen_metadata)")
        var hasIndex = false, hasBlob = false
        while try columns.next() {
            if columns.text(1) == "idx", columns.text(2).uppercased() == "INTEGER", columns.int(5) == 1 { hasIndex = true }
            if columns.text(1) == "data", columns.text(2).uppercased() == "BLOB" { hasBlob = true }
        }
        guard hasIndex, hasBlob else { throw TokenUsageReadError.schema }
        // Optional date support: no steps table/index means counts still work,
        // with unknown dates. Never query step_payload or use an unindexed join.
        let steps = try stepQuery(database)
        let maxBlob = min(budget.bytes, AntigravityTokenDecoder.maxBlobBytes)
        let statement = try database.prepare("""
            SELECT idx, length(data), CASE WHEN length(data)<=? THEN data END
            FROM gen_metadata WHERE idx>? ORDER BY idx LIMIT ?
            """)
        statement.bind(Int64(maxBlob), at: 1)
        statement.bind(cursor, at: 2); statement.bind(Int64(maxRows + 1), at: 3)
        var rows: [Row] = [], byteCount = 0, rowCount = 0, stepCount = 0, ended = false
        let now = Date()
        while rowCount < maxRows, ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            guard try statement.next() else { ended = true; break }
            let length = statement.int(1)
            guard length >= 0 else { throw TokenUsageReadError.schema }
            if length <= maxBlob, byteCount + Int(length) > maxBytes { break }
            let blob = statement.blob(2)
            byteCount += blob?.count ?? 0
            rowCount += 1
            let record = blob.flatMap { try? AntigravityTokenDecoder.decode($0) }
            var occurredAt: Int64?
            if let record, let index = record.firstStepIndex, record.executionKey != nil, let steps {
                // If this slice cannot finish the date lookup, leave the cursor
                // before this generation so the next request can retry it.
                guard rowCount < maxRows, ProcessInfo.processInfo.systemUptime < deadline else { break }
                steps.reset(); steps.bind(Int64(min(maxBytes - byteCount, AntigravityTokenDecoder.maxStepBlobBytes)), at: 1)
                steps.bind(index, at: 2)
                stepCount += 1; rowCount += 1
                if try steps.next() {
                    let stepLength = steps.int(0)
                    if stepLength <= AntigravityTokenDecoder.maxStepBlobBytes,
                       length + stepLength <= budget.bytes,
                       stepLength > maxBytes - byteCount { break }
                    if let metadata = steps.blob(1) {
                        byteCount += metadata.count
                        occurredAt = AntigravityTokenDecoder.stepCreatedAt(metadata, for: record, now: now)
                    }
                }
            }
            rows.append(Row(index: statement.int(0), record: record, occurredAt: occurredAt))
        }
        guard try fingerprint(url) == before, !immutable || !runtimeIsRunning() else {
            throw TokenUsageReadError.unavailable
        }
        return Slice(rows: rows, bytes: byteCount, ended: ended, fingerprint: before,
                     rowsRead: rowCount, stepRowsRead: stepCount)
    }

    private func stepQuery(_ database: TokenUsageDatabase) throws -> TokenUsageStatement? {
        let kind = try database.prepare("SELECT type FROM sqlite_schema WHERE name='steps'")
        guard try kind.next(), kind.text(0) == "table" else { return nil }
        let columns = try database.prepare("PRAGMA table_info(steps)")
        var indexed = false, metadata = false
        while try columns.next() {
            if columns.text(1) == "idx", columns.text(2).uppercased() == "INTEGER", columns.int(5) == 1 { indexed = true }
            if columns.text(1) == "metadata", columns.text(2).uppercased() == "BLOB" { metadata = true }
        }
        guard indexed, metadata else { return nil }
        return try database.prepare("SELECT length(metadata), CASE WHEN length(metadata)<=? THEN metadata END FROM steps WHERE idx=?")
    }

    private func fingerprint(_ url: URL) throws -> String {
        var parts: [String] = []
        // SHM reader bookkeeping is not a source-data change.
        for suffix in ["", "-wal"] {
            do {
                let a = try FileManager.default.attributesOfItem(atPath: url.path + suffix)
                parts.append("\(a[.systemFileNumber] ?? 0):\(a[.size] ?? 0):\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)")
            } catch {
                if suffix.isEmpty { throw error }
                parts.append("absent")
            }
        }
        return parts.joined(separator: "|")
    }

    private func configure(_ db: TokenUsageDatabase) throws {
        let version = try db.integer("PRAGMA user_version")
        // v1 included a model enum in input tokens. Do not reuse those totals.
        // A separate v2 file is rebuilt on demand; the old file is left intact.
        guard version == 0 || version == 2 else { throw TokenUsageReadError.schema }
        try db.run("CREATE TABLE IF NOT EXISTS sources (source TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, cursor INTEGER NOT NULL, pass INTEGER NOT NULL, complete INTEGER NOT NULL, touched INTEGER NOT NULL)")
        try db.run("CREATE TABLE IF NOT EXISTS records (source TEXT NOT NULL, idx INTEGER NOT NULL, pass INTEGER NOT NULL, response_key TEXT NOT NULL, model TEXT NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, occurred_ms INTEGER, PRIMARY KEY(source,idx))")
        try db.run("CREATE INDEX IF NOT EXISTS response_keys ON records(response_key)")
        if version == 0 { try db.run("PRAGMA user_version=2") }
    }

    private func loadSources(_ db: TokenUsageDatabase) throws -> [String: Source] {
        let query = try db.prepare("SELECT source,fingerprint,cursor,pass,complete,touched FROM sources LIMIT 513")
        var result: [String: Source] = [:]
        while try query.next() {
            result[query.text(0)] = Source(fingerprint: query.text(1), cursor: query.int(2),
                pass: query.int(3), complete: query.int(4) != 0, touched: query.int(5))
        }
        return result
    }

    private func saveSource(_ key: String, _ source: Source, cache: TokenUsageDatabase) throws {
        let update = try cache.prepare("INSERT OR REPLACE INTO sources VALUES(?,?,?,?,?,?)")
        update.bind(key, at: 1); update.bind(source.fingerprint, at: 2)
        update.bind(source.cursor, at: 3); update.bind(source.pass, at: 4)
        update.bind(source.complete ? 1 : 0, at: 5); update.bind(source.touched, at: 6)
        _ = try update.next()
    }

    private func removeSource(_ key: String, cache: TokenUsageDatabase) throws {
        for table in ["records", "sources"] {
            let query = try cache.prepare("DELETE FROM \(table) WHERE source=?")
            query.bind(key, at: 1); _ = try query.next()
        }
    }

    private func snapshot(_ cache: TokenUsageDatabase, files: Int, pending: Int, unavailable: Int,
                          limited: Bool, rows: Int, bytes: Int, stepRows: Int) throws -> AntigravityTokenSnapshot {
        // Dedupe forks/copies/retries by response hash, not by conversation index.
        // Conflicting copies are excluded instead of guessing or double-counting.
        let unique = """
            SELECT response_key, min(model) model, min(input) input, min(output) output, min(cache_read) cache_read,
                CASE WHEN min(occurred_ms)=max(occurred_ms) THEN min(occurred_ms) END occurred_ms
            FROM records WHERE response_key<>'' GROUP BY response_key
            HAVING min(model)=max(model) AND min(input)=max(input) AND min(output)=max(output) AND min(cache_read)=max(cache_read)
            """
        // One aggregate query. Exact timestamps allow correct regrouping after
        // a time-zone change, including local midnight and DST, without re-reading sources.
        let query = try cache.prepare("""
            SELECT model,date(occurred_ms/1000.0,'unixepoch','localtime') day,
                sum(input),sum(output),sum(cache_read),count(*)
            FROM (\(unique)) GROUP BY model,day
            """)
        var totals: [String: (input: Int64, output: Int64, cache: Int64, count: Int)] = [:]
        var daily: [String: Int64] = [:], undated = 0
        while try query.next() {
            let model = query.text(0), input = query.int(2), output = query.int(3), cacheRead = query.int(4), count = Int(query.int(5))
            var total = totals[model] ?? (0, 0, 0, 0)
            total.input += input; total.output += output; total.cache += cacheRead; total.count += count
            totals[model] = total
            let key = query.text(1)
            if !key.isEmpty {
                daily[key, default: 0] += input + output
            } else { undated += count }
        }
        let models = totals.keys.sorted().map { model in
            let total = totals[model]!
            return AntigravityTokenModel(id: model, input: total.input, output: total.output,
                                         cacheRead: total.cache, generations: total.count)
        }
        let knownKeys = try cache.integer("SELECT count(DISTINCT response_key) FROM records WHERE response_key<>''")
        let skipped = try cache.integer("SELECT count(*) FROM records WHERE response_key=''")
            + knownKeys - Int64(models.reduce(0) { $0 + $1.generations })
        return AntigravityTokenSnapshot(models: models, files: files, pendingFiles: pending,
            unavailableFiles: unavailable, skippedRecords: Int(skipped), limited: limited,
            checkedAt: Date(), rowsRead: rows, bytesRead: bytes, stepRowsRead: stepRows,
            dailyBuckets: daily.keys.sorted().map { .init(startDate: $0, tokens: daily[$0]!) },
            undatedGenerations: undated)
    }

    nonisolated static func hasRuntime() -> Bool {
        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else { return true } // Fail closed.
        var pids = [pid_t](repeating: 0, count: Int(expected) + 128)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, count < pids.count else { return true }
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var name = [CChar](repeating: 0, count: 1024)
            let length = proc_name(pid, &name, UInt32(name.count))
            guard length > 0 else { continue }
            let value = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()
            if value.contains("antigravity") || value.contains("language_server") { return true }
        }
        return false
    }
}
