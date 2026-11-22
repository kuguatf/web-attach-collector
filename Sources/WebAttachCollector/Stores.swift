import Foundation
import SQLite3

final class IncrementalStore {
    private var db: SQLiteDB?
    private let path: String
    private(set) var available = false

    init(path: String) {
        self.path = path
        do {
            let database = try SQLiteDB(path: path)
            try database.exec("""
            CREATE TABLE IF NOT EXISTS 增量记录 (
                记录编号 INTEGER PRIMARY KEY AUTOINCREMENT,
                分类名称 TEXT NOT NULL,
                附件标识 TEXT NOT NULL,
                来源页面地址 TEXT,
                内容校验值 TEXT,
                采集时间 TEXT,
                处理状态 TEXT
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_增量键 ON 增量记录(分类名称, 附件标识);
            """)
            let check = try database.prepare("PRAGMA quick_check;")
            let result = sqlite3_step(check)
            let value = result == SQLITE_ROW ? database.text(check, 0) : "ok"
            sqlite3_finalize(check)
            if (value ?? "ok").lowercased() != "ok" {
                database.close()
                self.db = nil
                self.available = false
                return
            }
            self.db = database
            self.available = true
        } catch {
            self.db = nil
            self.available = false
        }
    }

    func lookup(category: String, address: String) -> (found: Bool, md5: String?) {
        guard let db = db, let statement = try? db.prepare("SELECT 内容校验值 FROM 增量记录 WHERE 分类名称 = ? AND 附件标识 = ? LIMIT 1;") else {
            return (false, nil)
        }
        defer { sqlite3_finalize(statement) }
        db.bindText(statement, 1, category)
        db.bindText(statement, 2, address)
        guard sqlite3_step(statement) == SQLITE_ROW else { return (false, nil) }
        return (true, db.text(statement, 0))
    }

    func upsert(category: String, address: String, pageURL: String, md5: String?, time: String) throws {
        guard let db = db else { throw SQLiteError.open("增量记录不可用") }
        let sql = """
        INSERT INTO 增量记录 (分类名称, 附件标识, 来源页面地址, 内容校验值, 采集时间, 处理状态)
        VALUES (?, ?, ?, ?, ?, '成功')
        ON CONFLICT(分类名称, 附件标识) DO UPDATE SET
            来源页面地址 = excluded.来源页面地址,
            内容校验值 = excluded.内容校验值,
            采集时间 = excluded.采集时间,
            处理状态 = '成功';
        """
        let statement = try db.prepare(sql)
        defer { sqlite3_finalize(statement) }
        db.bindText(statement, 1, category)
        db.bindText(statement, 2, address)
        db.bindText(statement, 3, pageURL)
        db.bindText(statement, 4, md5)
        db.bindText(statement, 5, time)
        try db.stepDone(statement)
    }

    func clearAll() throws {
        guard let db = db else { return }
        try db.exec("DELETE FROM 增量记录;")
        try db.exec("VACUUM;")
    }

    func clear(categories: [String]) throws {
        guard let db = db, !categories.isEmpty else { return }
        for category in categories {
            let statement = try db.prepare("DELETE FROM 增量记录 WHERE 分类名称 = ?;")
            db.bindText(statement, 1, category)
            try db.stepDone(statement)
            sqlite3_finalize(statement)
        }
    }

    func count() -> Int {
        guard let db = db, let statement = try? db.prepare("SELECT COUNT(*) FROM 增量记录;") else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(db.int(statement, 0))
    }

    func close() {
        db?.close()
        db = nil
    }
}

enum RecordType: String {
    case attachment = "附件"
    case pageText = "正文"
}

struct CollectedRecord {
    let categoryName: String
    let pageTitle: String
    let pageURL: String
    let attachmentURL: String
    let fileName: String
    let size: Int64
    let content: String
    let md5: String
    let collectedAt: String
    var recordType: RecordType = .attachment
    var pageText: String = ""
    var status: String = "成功"
    var failureReason: String = ""
}

final class DatabaseOutput {
    private let path: String
    private var db: SQLiteDB?
    private var tableReady = false

    init(path: String) { self.path = path }

    private func ready() throws -> SQLiteDB {
        if let db = db, tableReady { return db }
        guard !path.trimmed.isEmpty else { throw SQLiteError.open("未配置数据库文件路径") }
        let database = try SQLiteDB(path: path)
        try database.exec("""
        CREATE TABLE IF NOT EXISTS 采集记录 (
            "记录编号" INTEGER PRIMARY KEY AUTOINCREMENT,
            "分类名称" TEXT,
            "页面标题" TEXT,
            "来源页面地址" TEXT,
            "附件地址" TEXT,
            "附件文件名" TEXT,
            "附件大小" INTEGER,
            "识别内容" TEXT,
            "内容校验值" TEXT,
            "采集时间" TEXT,
            "处理状态" TEXT,
            "失败原因" TEXT,
            "记录类型" TEXT DEFAULT '附件',
            "页面正文" TEXT
        );
        """)
        let existing = try columnNames(of: database)
        if !existing.contains("记录类型") {
            try database.exec("ALTER TABLE 采集记录 ADD COLUMN \"记录类型\" TEXT DEFAULT '附件';")
        }
        if !existing.contains("页面正文") {
            try database.exec("ALTER TABLE 采集记录 ADD COLUMN \"页面正文\" TEXT;")
        }
        db = database
        tableReady = true
        return database
    }

    private func columnNames(of database: SQLiteDB) throws -> Set<String> {
        let statement = try database.prepare("PRAGMA table_info(\"采集记录\");")
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = database.text(statement, 1) { names.insert(name) }
        }
        return names
    }

    func write(_ record: CollectedRecord, forceFull: Bool) throws -> Int64 {
        let database = try ready()
        if !forceFull {
            let select = try database.prepare("SELECT MAX(\"记录编号\") FROM 采集记录 WHERE \"分类名称\" = ? AND \"附件地址\" = ? AND \"记录类型\" = '附件';")
            database.bindText(select, 1, record.categoryName)
            database.bindText(select, 2, record.attachmentURL)
            let step = sqlite3_step(select)
            var existingID: Int64 = 0
            if step == SQLITE_ROW { existingID = database.int(select, 0) }
            sqlite3_finalize(select)
            if existingID > 0 {
                try updateRow(existingID, record: record)
                return existingID
            }
        }
        return try insert(record)
    }

    func writePageText(_ record: CollectedRecord, forceFull: Bool) throws -> Int64 {
        let database = try ready()
        if !forceFull {
            let select = try database.prepare("SELECT MAX(\"记录编号\") FROM 采集记录 WHERE \"分类名称\" = ? AND \"来源页面地址\" = ? AND \"记录类型\" = '正文';")
            database.bindText(select, 1, record.categoryName)
            database.bindText(select, 2, record.pageURL)
            let step = sqlite3_step(select)
            var existingID: Int64 = 0
            if step == SQLITE_ROW { existingID = database.int(select, 0) }
            sqlite3_finalize(select)
            if existingID > 0 {
                try updateRow(existingID, record: record)
                return existingID
            }
        }
        return try insert(record)
    }

    private func insert(_ record: CollectedRecord) throws -> Int64 {
        guard let database = db else { return 0 }
        let sql = """
        INSERT INTO 采集记录 ("分类名称","页面标题","来源页面地址","附件地址","附件文件名","附件大小","识别内容","内容校验值","采集时间","处理状态","失败原因","记录类型","页面正文")
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        database.bindText(statement, 1, record.categoryName)
        database.bindText(statement, 2, record.pageTitle)
        database.bindText(statement, 3, record.pageURL)
        database.bindText(statement, 4, record.attachmentURL)
        database.bindText(statement, 5, record.fileName)
        database.bindInt(statement, 6, record.size)
        database.bindText(statement, 7, record.content)
        database.bindText(statement, 8, record.md5.isEmpty ? nil : record.md5)
        database.bindText(statement, 9, record.collectedAt)
        database.bindText(statement, 10, record.status)
        database.bindText(statement, 11, record.failureReason)
        database.bindText(statement, 12, record.recordType.rawValue)
        database.bindText(statement, 13, record.pageText)
        try database.stepDone(statement)
        guard let handle = database.handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    private func updateRow(_ id: Int64, record: CollectedRecord) throws {
        guard let database = db else { return }
        let sql = """
        UPDATE 采集记录 SET "分类名称"=?, "页面标题"=?, "来源页面地址"=?, "附件地址"=?, "附件文件名"=?, "附件大小"=?, "识别内容"=?, "内容校验值"=?, "采集时间"=?, "处理状态"=?, "失败原因"=?, "记录类型"=?, "页面正文"=?
        WHERE "记录编号"=?;
        """
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        database.bindText(statement, 1, record.categoryName)
        database.bindText(statement, 2, record.pageTitle)
        database.bindText(statement, 3, record.pageURL)
        database.bindText(statement, 4, record.attachmentURL)
        database.bindText(statement, 5, record.fileName)
        database.bindInt(statement, 6, record.size)
        database.bindText(statement, 7, record.content)
        database.bindText(statement, 8, record.md5.isEmpty ? nil : record.md5)
        database.bindText(statement, 9, record.collectedAt)
        database.bindText(statement, 10, record.status)
        database.bindText(statement, 11, record.failureReason)
        database.bindText(statement, 12, record.recordType.rawValue)
        database.bindText(statement, 13, record.pageText)
        database.bindInt(statement, 14, id)
        try database.stepDone(statement)
    }

    func updateStatus(rowID: Int64, status: String, reason: String) {
        guard let database = db else { return }
        guard let statement = try? database.prepare("UPDATE 采集记录 SET \"处理状态\"=?, \"失败原因\"=? WHERE \"记录编号\"=?;") else { return }
        database.bindText(statement, 1, status)
        database.bindText(statement, 2, reason)
        database.bindInt(statement, 3, rowID)
        try? database.stepDone(statement)
        sqlite3_finalize(statement)
    }

    func close() {
        db?.close()
        db = nil
        tableReady = false
    }
}
