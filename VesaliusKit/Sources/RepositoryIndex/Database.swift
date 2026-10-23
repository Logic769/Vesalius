import Foundation
import SQLite3

public enum SQLValue: Sendable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Int32: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension UInt64: SQLBindable { public var sqlValue: SQLValue { .int(Int64(bitPattern: self)) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Substring: SQLBindable { public var sqlValue: SQLValue { .text(String(self)) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

public struct SQLiteError: Error, LocalizedError, Sendable {
    public let code: Int32
    public let message: String
    public let sql: String?

    public var errorDescription: String? {
        if let sql { return "SQLite error \(code): \(message) (in: \(sql.prefix(160)))" }
        return "SQLite error \(code): \(message)"
    }
}

/// A row cursor valid only inside the mapping closure.
public struct SQLRow {
    let statement: OpaquePointer

    public var columnCount: Int { Int(sqlite3_column_count(statement)) }

    public func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
    public func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
    public func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    public func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    public func bool(_ index: Int32) -> Bool { sqlite3_column_int64(statement, index) != 0 }

    public func string(_ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    public func optionalString(_ index: Int32) -> String? {
        isNull(index) ? nil : string(index)
    }

    public func optionalInt(_ index: Int32) -> Int? {
        isNull(index) ? nil : int(index)
    }

    public func optionalInt64(_ index: Int32) -> Int64? {
        isNull(index) ? nil : int64(index)
    }

    public func optionalDouble(_ index: Int32) -> Double? {
        isNull(index) ? nil : double(index)
    }

    public func blob(_ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: pointer, count: count)
    }

    public func columnName(_ index: Int32) -> String {
        String(cString: sqlite3_column_name(statement, index))
    }

    public func value(_ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: .int(int64(index))
        case SQLITE_FLOAT: .double(double(index))
        case SQLITE_TEXT: .text(string(index))
        case SQLITE_BLOB: blob(index).map { .blob($0) } ?? .null
        default: .null
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A serialized SQLite connection. All access goes through a recursive lock, so a connection can be
/// shared across tasks; use separate connections for concurrent readers (WAL mode).
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var statementCache: [String: OpaquePointer] = [:]
    public let path: String
    public let isReadOnly: Bool

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        self.isReadOnly = readOnly
        var db: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: code, message: message, sql: nil)
        }
        handle = db
        sqlite3_busy_timeout(db, 10_000)
        sqlite3_extended_result_codes(db, 1)
        if !readOnly {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-32000;")
        } else {
            try execute("PRAGMA query_only=ON; PRAGMA cache_size=-16000;")
        }
    }

    deinit {
        for statement in statementCache.values { sqlite3_finalize(statement) }
        if let handle { sqlite3_close_v2(handle) }
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
    }

    /// Executes one or more statements without results.
    public func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &error)
        if code != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw SQLiteError(code: code, message: message, sql: sql)
        }
    }

    private func prepared(_ sql: String, cache: Bool) throws -> OpaquePointer {
        if cache, let statement = statementCache[sql] {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            return statement
        }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw SQLiteError(code: code, message: errorMessage, sql: sql)
        }
        if cache { statementCache[sql] = statement }
        return statement
    }

    private func bind(_ values: [any SQLBindable], to statement: OpaquePointer, sql: String) throws {
        for (offset, bindable) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch bindable.sqlValue {
            case .null: code = sqlite3_bind_null(statement, index)
            case .int(let value): code = sqlite3_bind_int64(statement, index, value)
            case .double(let value): code = sqlite3_bind_double(statement, index, value)
            case .text(let value): code = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case .blob(let value):
                code = value.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
            }
            if code != SQLITE_OK { throw SQLiteError(code: code, message: errorMessage, sql: sql) }
        }
    }

    /// Runs a statement that returns no rows. Statements are cached by SQL text.
    @discardableResult
    public func run(_ sql: String, _ values: [any SQLBindable] = []) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepared(sql, cache: true)
        defer { sqlite3_reset(statement) }
        try bind(values, to: statement, sql: sql)
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW { code = sqlite3_step(statement) }
        guard code == SQLITE_DONE else { throw SQLiteError(code: code, message: errorMessage, sql: sql) }
        return Int(sqlite3_changes(handle))
    }

    /// Runs a query and maps every row.
    public func query<T>(_ sql: String, _ values: [any SQLBindable] = [], cache: Bool = true, _ map: (SQLRow) throws -> T) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepared(sql, cache: cache)
        defer {
            if cache { sqlite3_reset(statement) } else { sqlite3_finalize(statement) }
        }
        try bind(values, to: statement, sql: sql)
        var results: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                results.append(try map(SQLRow(statement: statement)))
            } else if code == SQLITE_DONE {
                break
            } else {
                throw SQLiteError(code: code, message: errorMessage, sql: sql)
            }
        }
        return results
    }

    /// Iterates rows without materialising them.
    public func forEach(_ sql: String, _ values: [any SQLBindable] = [], _ body: (SQLRow) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepared(sql, cache: false)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, sql: sql)
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                try body(SQLRow(statement: statement))
            } else if code == SQLITE_DONE {
                break
            } else {
                throw SQLiteError(code: code, message: errorMessage, sql: sql)
            }
        }
    }

    public func queryOne<T>(_ sql: String, _ values: [any SQLBindable] = [], _ map: (SQLRow) throws -> T) throws -> T? {
        try query(sql, values, map).first
    }

    public func scalarInt(_ sql: String, _ values: [any SQLBindable] = []) throws -> Int {
        try queryOne(sql, values) { $0.int(0) } ?? 0
    }

    public var lastInsertRowID: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Runs `body` inside a transaction (savepoints make nesting safe).
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let name = "sp\(UInt32.random(in: 0...UInt32.max))"
        try execute("SAVEPOINT \(name)")
        do {
            let result = try body()
            try execute("RELEASE \(name)")
            return result
        } catch {
            try? execute("ROLLBACK TO \(name); RELEASE \(name)")
            throw error
        }
    }

    /// Generic read-only SQL for power users and agents (`vesalius query`).
    public func rawQuery(_ sql: String, limit: Int) throws -> (columns: [String], rows: [[SQLValue]]) {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepared(sql, cache: false)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) != 0 else {
            throw SQLiteError(code: SQLITE_READONLY, message: "Only read-only statements are allowed", sql: sql)
        }
        let row = SQLRow(statement: statement)
        var columns: [String] = []
        var rows: [[SQLValue]] = []
        while rows.count < limit {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                if columns.isEmpty {
                    columns = (0..<Int32(row.columnCount)).map { row.columnName($0) }
                }
                rows.append((0..<Int32(row.columnCount)).map { row.value($0) })
            } else if code == SQLITE_DONE {
                break
            } else {
                throw SQLiteError(code: code, message: errorMessage, sql: sql)
            }
        }
        if columns.isEmpty {
            columns = (0..<Int32(sqlite3_column_count(statement))).map { String(cString: sqlite3_column_name(statement, $0)) }
        }
        return (columns, rows)
    }

    /// Checkpoints the WAL so the main database file is self-contained.
    public func checkpoint() {
        lock.lock()
        defer { lock.unlock() }
        sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
    }

    public func optimize() {
        try? execute("PRAGMA optimize;")
    }
}

extension Array where Element == Int64 {
    /// A comma-separated id list for `IN (...)` clauses (ids are integers, so this is injection-safe).
    public var sqlList: String { isEmpty ? "NULL" : map(String.init).joined(separator: ",") }
}
