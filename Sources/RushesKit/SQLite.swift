import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// The few parts of SQLite this app needs, wrapped so nothing else touches the C API. One
/// connection is not shared between threads: every owner serialises its own calls.
public final class SQLiteDB {
    public enum Value {
        case null
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)

        public var int: Int64? {
            switch self {
            case let .int(value): value
            case let .double(value): Int64(value)
            case let .text(value): Int64(value)
            default: nil
            }
        }

        public var double: Double? {
            switch self {
            case let .int(value): Double(value)
            case let .double(value): value
            case let .text(value): Double(value)
            default: nil
            }
        }

        public var text: String? {
            switch self {
            case let .text(value): value
            case let .int(value): String(value)
            case let .double(value): String(value)
            case let .blob(value): String(data: value, encoding: .utf8)
            case .null: nil
            }
        }

        public var blob: Data? {
            switch self {
            case let .blob(value): value
            case let .text(value): Data(value.utf8)
            default: nil
            }
        }
    }

    public typealias Row = [Value]

    private var handle: OpaquePointer?
    public let path: String

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw SQLiteError(message: message)
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close(handle) }

    public func execute(_ sql: String, _ parameters: [Value] = []) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw failure() }
    }

    @discardableResult
    public func query(_ sql: String, _ parameters: [Value] = [], _ each: (Row) -> Void) throws -> Int {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var count = 0
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            let columns = sqlite3_column_count(statement)
            var row: Row = []
            row.reserveCapacity(Int(columns))
            for index in 0 ..< columns {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(statement, index)))
                case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(statement, index)))
                case SQLITE_TEXT:
                    let bytes = sqlite3_column_bytes(statement, index)
                    if let pointer = sqlite3_column_text(statement, index) {
                        row.append(.text(String(decoding: UnsafeBufferPointer(start: pointer, count: Int(bytes)), as: UTF8.self)))
                    } else {
                        row.append(.null)
                    }
                case SQLITE_BLOB:
                    let bytes = Int(sqlite3_column_bytes(statement, index))
                    if bytes > 0, let pointer = sqlite3_column_blob(statement, index) {
                        row.append(.blob(Data(bytes: pointer, count: bytes)))
                    } else {
                        row.append(.blob(Data()))
                    }
                default: row.append(.null)
                }
            }
            each(row)
            count += 1
        }
        return count
    }

    public func rows(_ sql: String, _ parameters: [Value] = []) throws -> [Row] {
        var result: [Row] = []
        try query(sql, parameters) { result.append($0) }
        return result
    }

    public func scalarInt(_ sql: String, _ parameters: [Value] = []) throws -> Int64? {
        try rows(sql, parameters).first?.first?.int
    }

    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    private func prepare(_ sql: String, _ parameters: [Value]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, index)
            case let .int(number): sqlite3_bind_int64(statement, index, number)
            case let .double(number): sqlite3_bind_double(statement, index, number)
            case let .text(text): sqlite3_bind_text(statement, index, text, -1, transient)
            case let .blob(data):
                data.withUnsafeBytes { buffer in
                    _ = sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), transient)
                }
            }
        }
        return statement
    }

    private func failure() -> SQLiteError {
        SQLiteError(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error")
    }
}

extension SQLiteDB.Value: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension SQLiteDB.Value {
    public static func optional(_ text: String?) -> SQLiteDB.Value { text.map { .text($0) } ?? .null }
    public static func optional(_ number: Int64?) -> SQLiteDB.Value { number.map { .int($0) } ?? .null }
}
