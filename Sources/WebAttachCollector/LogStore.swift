import Foundation

struct LogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let type: String
    let category: String?
    let message: String

    var line: String {
        let stamp = TimeFormat.logTime(time)
        if let category = category, !category.isEmpty {
            return "[\(stamp)] [\(type)][\(category)] \(message)"
        }
        return "[\(stamp)] [\(type)] \(message)"
    }
}

final class LogStore: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []

    private let fileQueue = DispatchQueue(label: "com.webattach.log")
    private var fileHandle: FileHandle?
    private var currentDay: String?

    init() {
        AppPaths.ensureDirectories()
        cleanupOldLogs()
        rotateIfNeeded()
    }

    deinit {
        try? fileHandle?.close()
    }

    func add(_ type: String, category: String? = nil, _ message: String) {
        let entry = LogEntry(time: Date(), type: type, category: category, message: message)
        writeToFile(entry)
        if Thread.isMainThread {
            entries.append(entry)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.entries.append(entry)
            }
        }
    }

    func info(_ message: String, category: String? = nil) { add("信息", category: category, message) }
    func discovered(_ message: String, category: String) { add("发现", category: category, message) }
    func skipped(_ message: String, category: String? = nil) { add("跳过", category: category, message) }
    func added(_ message: String, category: String) { add("新增", category: category, message) }
    func completed(_ message: String, category: String) { add("完成", category: category, message) }
    func failed(_ message: String, category: String? = nil) { add("失败", category: category, message) }
    func summary(_ message: String) { add("汇总", message) }
    func smart(_ message: String) { add("智能", message) }

    func clear() {        if Thread.isMainThread {
            entries.removeAll()
        } else {
            DispatchQueue.main.async { self.entries.removeAll() }
        }
        fileQueue.async { [weak self] in
            guard let self = self else { return }
            try? self.fileHandle?.close()
            self.fileHandle = nil
            self.currentDay = nil
            let url = AppPaths.todayLogFile()
            try? FileManager.default.removeItem(at: url)
            self.rotateIfNeeded()
        }
    }

    var plainText: String {
        entries.map { $0.line }.joined(separator: "\n")
    }

    func flush() {
        fileQueue.sync {}
    }

    private func writeToFile(_ entry: LogEntry) {
        fileQueue.async { [weak self] in
            guard let self = self else { return }
            self.rotateIfNeeded()
            guard let handle = self.fileHandle else { return }
            let text = entry.line + "\n"
            if let data = text.data(using: .utf8) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.synchronize()
            }
        }
    }

    private func rotateIfNeeded() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: Date())
        guard day != currentDay else { return }
        try? fileHandle?.close()
        currentDay = day
        AppPaths.ensureDirectories()
        let url = AppPaths.logsDir.appendingPathComponent(day + ".log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
    }

    private func cleanupOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: AppPaths.logsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        for file in files where file.pathExtension == "log" {
            let name = file.deletingPathExtension().lastPathComponent
            if let date = f.date(from: name), date < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }
}
