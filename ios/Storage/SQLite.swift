import Foundation
import SQLite3

// Taken from acorn's ios/Acorn/Storage/SQLite.swift, by way of The Shelf's copy.
// Changes from acorn's: SQLITE_TRANSIENT is a computed property on the class
// rather than a global, because Swift 6 rejects a global `let` of a type that is
// not Sendable; and the class is `@unchecked Sendable`, which is true because
// every use of the handle goes through its own serial queue.

enum SQLError: LocalizedError {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)

    var errorDescription: String? {
        switch self {
        case .open(let m):            return "Could not open database: \(m)"
        case .prepare(let m, let s):  return "Could not prepare statement: \(m)\nSQL: \(s)"
        case .step(let m, let s):     return "Query failed: \(m)\nSQL: \(s)"
        }
    }
}

/// Anything bindable to a statement parameter.
enum SQLValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case blob(Data)
    case null

    static func from(_ any: Any?) -> SQLValue {
        switch any {
        case nil:                    return .null
        case let v as String:        return .text(v)
        case let v as Int:           return .int(Int64(v))
        case let v as Int64:         return .int(v)
        case let v as Bool:          return .int(v ? 1 : 0)
        case let v as Double:        return .double(v)
        case let v as Data:          return .blob(v)
        default:                     return .null
        }
    }
}

/// One result row, addressed by column name.
struct Row {
    private let values: [String: SQLValue]

    init(values: [String: SQLValue]) { self.values = values }

    func string(_ key: String) -> String? {
        if case .text(let s)? = values[key] { return s }
        return nil
    }

    func int(_ key: String) -> Int64? {
        switch values[key] {
        case .int(let i)?:    return i
        case .double(let d)?: return Int64(d)
        case .text(let s)?:   return Int64(s)
        default:              return nil
        }
    }

    func double(_ key: String) -> Double? {
        switch values[key] {
        case .double(let d)?: return d
        case .int(let i)?:    return Double(i)
        case .text(let s)?:   return Double(s)
        default:              return nil
        }
    }

    func bool(_ key: String) -> Bool { (int(key) ?? 0) != 0 }
    func data(_ key: String) -> Data? {
        if case .blob(let d)? = values[key] { return d }
        return nil
    }
}

/// Thin synchronous wrapper over the system sqlite3. Serialised behind one queue:
/// every caller (the store and the sync engine) shares a single handle.
final class SQLite: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "graft.sqlite")

    /// SQLite's own docs call this "the destructor constant" - passing it tells SQLite
    /// to copy the bound bytes rather than assume our buffer outlives the statement.
    /// Omitting it is the classic source of garbage strings in bound parameters.
    private static var SQLITE_TRANSIENT: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLError.open(message)
        }
        // WAL matches the server's journal mode and keeps reads from blocking on writes.
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("PRAGMA busy_timeout=5000;")
    }

    deinit { if let handle { sqlite3_close_v2(handle) } }

    private var lastMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    /// Multi-statement DDL. Not for anything carrying user input.
    func execute(_ sql: String) throws {
        try queue.sync {
            var error: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? lastMessage
                sqlite3_free(error)
                throw SQLError.step(message, sql: sql)
            }
        }
    }

    @discardableResult
    func run(_ sql: String, _ params: [Any?] = []) throws -> Int {
        try queue.sync {
            let statement = try prepareLocked(sql, params)
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else {
                throw SQLError.step(lastMessage, sql: sql)
            }
            return Int(sqlite3_changes(handle))
        }
    }

    func query(_ sql: String, _ params: [Any?] = []) throws -> [Row] {
        try queue.sync {
            let statement = try prepareLocked(sql, params)
            defer { sqlite3_finalize(statement) }

            let columnCount = sqlite3_column_count(statement)
            var names: [String] = []
            names.reserveCapacity(Int(columnCount))
            for i in 0..<columnCount {
                names.append(sqlite3_column_name(statement, i).map { String(cString: $0) } ?? "\(i)")
            }

            var rows: [Row] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw SQLError.step(lastMessage, sql: sql) }

                var values: [String: SQLValue] = [:]
                for i in 0..<columnCount {
                    values[names[Int(i)]] = readColumn(statement, i)
                }
                rows.append(Row(values: values))
            }
            return rows
        }
    }

    /// Runs `body` in a transaction, rolling back if it throws. `body` must use the
    /// `unsafe*` variants below - the queue is already held.
    func transaction(_ body: () throws -> Void) throws {
        try queue.sync {
            guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw SQLError.step(lastMessage, sql: "BEGIN IMMEDIATE")
            }
            do {
                try body()
                // A COMMIT that fails must not read as success: the caller
                // would record rows as written that never reached the file.
                guard sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                    throw SQLError.step(lastMessage, sql: "COMMIT")
                }
            } catch {
                sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    /// Only legal from inside `transaction`.
    @discardableResult
    func unsafeRun(_ sql: String, _ params: [Any?] = []) throws -> Int {
        let statement = try prepareLocked(sql, params)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLError.step(lastMessage, sql: sql)
        }
        return Int(sqlite3_changes(handle))
    }

    // MARK: - internals

    private func prepareLocked(_ sql: String, _ params: [Any?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLError.prepare(lastMessage, sql: sql)
        }
        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            switch SQLValue.from(param) {
            case .text(let s):   sqlite3_bind_text(statement, index, s, -1, Self.SQLITE_TRANSIENT)
            case .int(let i):    sqlite3_bind_int64(statement, index, i)
            case .double(let d): sqlite3_bind_double(statement, index, d)
            case .null:          sqlite3_bind_null(statement, index)
            case .blob(let d):
                if d.isEmpty {
                    sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    _ = d.withUnsafeBytes { raw in
                        sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(d.count), Self.SQLITE_TRANSIENT)
                    }
                }
            }
        }
        return statement
    }

    private func readColumn(_ statement: OpaquePointer?, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: pointer))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: pointer, count: count))
        default:
            return .null
        }
    }
}
