import Foundation
import SQLite3

enum TokenUsageReadError: Error { case unavailable, schema, budget }

/// Internal SQLite wrapper: no subprocess, no connection retained while idle.
final class TokenUsageDatabase {
    let handle: OpaquePointer
    private var deadlinePointer: UnsafeMutablePointer<TimeInterval>?

    init(path: String, readOnly: Bool) throws {
        var database: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
            | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw TokenUsageReadError.unavailable
        }
        handle = database
        sqlite3_busy_timeout(handle, 0)
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 2_097_152)
        sqlite3_limit(handle, SQLITE_LIMIT_SQL_LENGTH, 16_384)
        try run("PRAGMA trusted_schema=OFF")
        try run("PRAGMA cache_size=-256")
        if readOnly { try run("PRAGMA query_only=ON") }
    }

    deinit {
        sqlite3_close(handle)
        deadlinePointer?.deinitialize(count: 1)
        deadlinePointer?.deallocate()
    }

    func limitWork(until deadline: TimeInterval) {
        if let deadlinePointer {
            deadlinePointer.pointee = deadline
            return
        }
        let pointer = UnsafeMutablePointer<TimeInterval>.allocate(capacity: 1)
        pointer.initialize(to: deadline)
        deadlinePointer = pointer
        sqlite3_progress_handler(handle, 1000, { context in
            guard let context else { return 1 }
            return ProcessInfo.processInfo.systemUptime >= context.assumingMemoryBound(to: TimeInterval.self).pointee ? 1 : 0
        }, pointer)
    }

    func prepare(_ sql: String) throws -> TokenUsageStatement {
        try TokenUsageStatement(database: self, sql: sql)
    }

    func run(_ sql: String) throws {
        let statement = try prepare(sql)
        while try statement.next() {}
    }

    func integer(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        guard try statement.next() else { throw TokenUsageReadError.schema }
        return statement.int(0)
    }
}

final class TokenUsageStatement {
    // Keep the connection and its progress callback alive through finalization.
    private let database: TokenUsageDatabase
    private let handle: OpaquePointer
    init(database: TokenUsageDatabase, sql: String) throws {
        self.database = database
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database.handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw TokenUsageReadError.schema
        }
        handle = statement
    }
    deinit { sqlite3_finalize(handle) }

    func bind(_ value: String, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(handle, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    func bind(_ value: Int64, at index: Int32) { sqlite3_bind_int64(handle, index, value) }
    func bindNull(at index: Int32) { sqlite3_bind_null(handle, index) }
    func reset() { sqlite3_reset(handle); sqlite3_clear_bindings(handle) }
    func next() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw TokenUsageReadError.unavailable
        }
    }
    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func text(_ column: Int32) -> String {
        sqlite3_column_text(handle, column).map { String(cString: $0) } ?? ""
    }
    func blob(_ column: Int32) -> Data? {
        guard sqlite3_column_type(handle, column) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(handle, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, column)))
    }
}
