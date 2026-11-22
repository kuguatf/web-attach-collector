import Foundation

final class RunLock {
    private let url: URL
    private var fileDescriptor: Int32 = -1
    private(set) var isHeld = false

    init(url: URL) { self.url = url }

    static func acquire(url: URL) -> RunLock? {
        let lock = RunLock(url: url)
        if lock.tryAcquire() { return lock }
        return nil
    }

    private func tryAcquire() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let content = try? String(contentsOf: url, encoding: .utf8),
           let pid = pid_t(content.trimmed) {
            if kill(pid, 0) == 0 {
                return false
            }
            try? fm.removeItem(at: url)
        }

        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd < 0 {
            // 可能是竞态，再判断一次持有进程
            if let content = try? String(contentsOf: url, encoding: .utf8),
               let pid = pid_t(content.trimmed), kill(pid, 0) == 0 {
                return false
            }
            try? fm.removeItem(at: url)
            let retry = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if retry < 0 { return false }
            fileDescriptor = retry
        } else {
            fileDescriptor = fd
        }

        let text = "\(getpid())\n"
        _ = text.withCString { ptr in
            write(fileDescriptor, ptr, strlen(ptr))
        }
        isHeld = true
        return true
    }

    func release() {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        if isHeld {
            try? FileManager.default.removeItem(at: url)
            isHeld = false
        }
    }

    deinit { release() }
}
