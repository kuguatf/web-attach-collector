import Foundation
import SQLite3

enum SQLiteError: LocalizedError {
    case open(String)
    case prepare(String)
    case step(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .open(let message): return "数据库无法打开：\(message)"
        case .prepare(let message): return "数据库语句错误：\(message)"
        case .step(let message): return "数据库写入失败：\(message)"
        case .busy: return "数据库文件被占用，请关闭后重试"
        }
    }
}

final class SQLiteDB {
    private(set) var handle: OpaquePointer?
    let path: String

    init(path: String) throws {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK, let db = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            sqlite3_close(db)
            throw SQLiteError.open(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 3000)
        try exec("PRAGMA journal_mode=WAL;")
    }

    deinit { close() }

    func close() {
        if let handle = handle {
            sqlite3_close(handle)
            self.handle = nil
        }
    }

    func exec(_ sql: String) throws {
        guard let handle = handle else { throw SQLiteError.open("连接已关闭") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED { throw SQLiteError.busy }
            throw SQLiteError.prepare(message)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle = handle else { throw SQLiteError.open("连接已关闭") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement = statement else {
            if result == SQLITE_BUSY || result == SQLITE_LOCKED { throw SQLiteError.busy }
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        return statement
    }

    func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value = value {
            sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bindInt(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(statement, index, value)
    }

    func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        if result == SQLITE_BUSY || result == SQLITE_LOCKED { throw SQLiteError.busy }
        guard result == SQLITE_DONE else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            throw SQLiteError.step(message)
        }
    }

    func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let ptr = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: ptr)
    }

    func int(_ statement: OpaquePointer, _ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }
}
