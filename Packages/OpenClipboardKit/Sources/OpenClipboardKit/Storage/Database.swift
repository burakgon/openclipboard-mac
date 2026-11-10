import Foundation
import SQLite3

struct DatabaseError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite error \(code): \(message)" }
}

enum SQLValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    static func optional(_ string: String?) -> SQLValue { string.map(SQLValue.text) ?? .null }
    static func optional(_ date: Date?) -> SQLValue { date.map { .real($0.timeIntervalSince1970) } ?? .null }
    static func date(_ date: Date) -> SQLValue { .real(date.timeIntervalSince1970) }
}

/// Tells SQLite to copy bound text and blobs, because the Swift values go away after the call.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One SQLite connection with a cache of prepared statements.
///
/// Not thread-safe by design: the connection is opened without SQLite's own mutex and is
/// owned by a single actor (`HistoryStore`), which serializes every call.
final class Database {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open the database"
            sqlite3_close_v2(handle)
            handle = nil
            throw DatabaseError(code: status, message: message)
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    /// Runs statements that take no parameters and return nothing, such as schema changes.
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &error)
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw DatabaseError(code: status, message: message)
        }
    }

    /// Runs one statement and returns the number of rows it changed.
    @discardableResult
    func run(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        let statement = try prepare(sql, values)
        defer { reset(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw lastError(status) }
        return Int(sqlite3_changes(handle))
    }

    /// Runs a query and maps each row.
    func query<T>(_ sql: String, _ values: [SQLValue] = [], _ map: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { reset(statement) }
        var rows: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                rows.append(try map(Row(statement: statement)))
            } else if status == SQLITE_DONE {
                return rows
            } else {
                throw lastError(status)
            }
        }
    }

    /// The first column of the first row, for `SELECT COUNT(*)` and the like.
    func scalar(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        try query(sql, values) { $0.integer(0) }.first ?? 0
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Runs `body` in a transaction that is rolled back when it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var prepared: OpaquePointer?
            let status = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
            guard status == SQLITE_OK, let prepared else { throw lastError(status) }
            statements[sql] = prepared
            statement = prepared
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null:
                status = sqlite3_bind_null(statement, index)
            case .integer(let integer):
                status = sqlite3_bind_int64(statement, index, integer)
            case .real(let double):
                status = sqlite3_bind_double(statement, index, double)
            case .text(let string):
                status = sqlite3_bind_text(statement, index, string, -1, transient)
            case .blob(let data):
                if data.isEmpty {
                    status = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    status = data.withUnsafeBytes {
                        sqlite3_bind_blob64(statement, index, $0.baseAddress, sqlite3_uint64($0.count), transient)
                    }
                }
            }
            guard status == SQLITE_OK else {
                reset(statement)
                throw lastError(status)
            }
        }
        return statement
    }

    private func reset(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func lastError(_ code: Int32) -> DatabaseError {
        DatabaseError(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")
    }

    /// The columns of the row a query is currently on.
    struct Row {
        fileprivate let statement: OpaquePointer

        func integer(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        func real(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
        func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }

        func text(_ index: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: pointer)
        }

        func blob(_ index: Int32) -> Data? {
            guard !isNull(index) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
            return Data(bytes: bytes, count: count)
        }

        func date(_ index: Int32) -> Date? {
            isNull(index) ? nil : Date(timeIntervalSince1970: real(index))
        }
    }
}
