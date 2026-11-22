import Foundation

enum AppPaths {
    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("网页附件采集识别工具", isDirectory: true)
    }

    static var configDir: URL { appSupport.appendingPathComponent("config", isDirectory: true) }
    static var defaultConfigFile: URL { configDir.appendingPathComponent("default.json") }
    static var incrementalDB: URL { appSupport.appendingPathComponent("incremental.sqlite") }
    static var smartCacheDB: URL { appSupport.appendingPathComponent("smart-cache.sqlite") }
    static var attachmentsDir: URL { appSupport.appendingPathComponent("attachments", isDirectory: true) }
    static var lockFile: URL { appSupport.appendingPathComponent("collector.lock") }

    static var logsDir: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("网页附件采集识别工具", isDirectory: true)
    }

    @discardableResult
    static func ensureDirectories() -> Bool {
        let fm = FileManager.default
        for dir in [appSupport, configDir, attachmentsDir, logsDir] {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                return false
            }
        }
        return true
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func todayLogFile() -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return logsDir.appendingPathComponent(f.string(from: Date()) + ".log")
    }
}

enum FileUtil {
    static func uniqueFile(in directory: URL, name: String) -> URL {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var index = 1
        while fm.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base)(\(index))" : "\(base)(\(index)).\(ext)"
            candidate = directory.appendingPathComponent(next)
            index += 1
        }
        return candidate
    }

    static func sanitizeFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|")
        var result = name.components(separatedBy: illegal).joined(separator: "_")
        result = result.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { result = "附件" }
        if result.count > 180 { result = String(result.prefix(180)) }
        return result
    }

    static func md5(of url: URL) -> String? {        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }
        var context = MD5Context()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read < 0 { return nil }
            if read == 0 { break }
            context.update(buffer[0..<read])
        }
        return context.finalize()
    }

    static func md5(of text: String) -> String {
        var context = MD5Context()
        let bytes = Array(text.utf8)
        context.update(bytes[0..<bytes.count])
        return context.finalize()
    }

    static func isWritableDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return FileManager.default.isWritableFile(atPath: url.path)
    }
}

/// 轻量 MD5 实现（仅用于内容校验值，不用于安全用途）。
struct MD5Context {
    private var a: UInt32 = 0x67452301
    private var b: UInt32 = 0xefcdab89
    private var c: UInt32 = 0x98badcfe
    private var d: UInt32 = 0x10325476
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    private static let s: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
    ]

    private static let k: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
    ]

    mutating func update<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        let incoming = Array(bytes)
        length &+= UInt64(incoming.count) * 8
        buffer.append(contentsOf: incoming)
        var offset = 0
        while buffer.count - offset >= 64 {
            process(Array(buffer[offset..<(offset + 64)]))
            offset += 64
        }
        if offset > 0 { buffer.removeFirst(offset) }
    }

    private mutating func process(_ chunk: [UInt8]) {
        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let j = i * 4
            m[i] = UInt32(chunk[j]) | (UInt32(chunk[j + 1]) << 8) | (UInt32(chunk[j + 2]) << 16) | (UInt32(chunk[j + 3]) << 24)
        }
        var aa = a, bb = b, cc = c, dd = d
        for i in 0..<64 {
            var f: UInt32
            var g: Int
            if i < 16 {
                f = (bb & cc) | (~bb & dd); g = i
            } else if i < 32 {
                f = (dd & bb) | (~dd & cc); g = (5 * i + 1) % 16
            } else if i < 48 {
                f = bb ^ cc ^ dd; g = (3 * i + 5) % 16
            } else {
                f = cc ^ (bb | ~dd); g = (7 * i) % 16
            }
            f = f &+ aa &+ MD5Context.k[i] &+ m[g]
            aa = dd
            dd = cc
            cc = bb
            let shift = MD5Context.s[i]
            bb = bb &+ ((f << shift) | (f >> (32 - shift)))
        }
        a = a &+ aa
        b = b &+ bb
        c = c &+ cc
        d = d &+ dd
    }

    mutating func finalize() -> String {
        var padding: [UInt8] = [0x80]
        let rem = (buffer.count + 1) % 64
        let zeros = rem <= 56 ? (56 - rem) : (120 - rem)
        padding.append(contentsOf: [UInt8](repeating: 0, count: zeros))
        var bits = length
        for _ in 0..<8 {
            padding.append(UInt8(bits & 0xff))
            bits >>= 8
        }
        let extra = padding
        updateWithoutLength(extra)
        return [a, b, c, d].map { word in
            (0..<4).map { i in String(format: "%02x", (word >> (UInt32(i) * 8)) & 0xff) }.joined()
        }.joined()
    }

    private mutating func updateWithoutLength(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
        var offset = 0
        while buffer.count - offset >= 64 {
            process(Array(buffer[offset..<(offset + 64)]))
            offset += 64
        }
        if offset > 0 { buffer.removeFirst(offset) }
    }
}
