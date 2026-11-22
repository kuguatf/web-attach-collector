import Foundation

enum ObsidianOutcome {
    case written
    case skipped(String)
}

enum ObsidianError: LocalizedError {
    case invalidVault
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidVault: return "Obsidian 知识库路径无效，请重新选择"
        case .writeFailed(let reason): return "Obsidian 写入失败：\(reason)"
        }
    }
}

final class ObsidianOutput {
    let config: ObsidianOutputConfig
    let log: LogStore

    init(config: ObsidianOutputConfig, log: LogStore) {
        self.config = config
        self.log = log
    }

    func write(record: CollectedRecord, attachmentFile: URL, forceFull: Bool, md5: String) throws -> ObsidianOutcome {
        let root = URL(fileURLWithPath: AppPaths.expand(config.vaultPath), isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ObsidianError.invalidVault
        }

        let notesDir = root.appendingPathComponent(config.notesFolder.isEmpty ? "网页采集笔记" : config.notesFolder, isDirectory: true)
        let assetsDir = root.appendingPathComponent(config.assetsFolder.isEmpty ? "assets" : config.assetsFolder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        } catch {
            throw ObsidianError.writeFailed(error.localizedDescription)
        }

        let baseName = (record.fileName as NSString).deletingPathExtension
        let ext = (record.fileName as NSString).pathExtension
        var name = baseName
        var noteURL = notesDir.appendingPathComponent(name + ".md")
        var assetURL = assetsDir.appendingPathComponent(record.fileName)
        var suffix = 2

        if FileManager.default.fileExists(atPath: noteURL.path) {
            let existingSource = Self.sourceAddress(ofNoteAt: noteURL)
            let sameSource = existingSource.map { Address.normalize($0) == Address.normalize(record.pageURL) } ?? false
            if sameSource {
                if !forceFull {
                    return .skipped("笔记已存在，跳过")
                }
                // 同一来源、强制全量：覆盖；若内容校验值变化，日志说明。
                if let existingMD5 = FileUtil.md5(of: assetURL), existingMD5 != md5 {
                    log.info("附件内容已更新，覆盖写入", category: record.categoryName)
                }
                try? FileManager.default.removeItem(at: noteURL)
                try? FileManager.default.removeItem(at: assetURL)
            } else {
                while true {
                    let candidate = "\(baseName)-\(suffix)"
                    noteURL = notesDir.appendingPathComponent(candidate + ".md")
                    assetURL = assetsDir.appendingPathComponent(ext.isEmpty ? candidate : candidate + "." + ext)
                    if !FileManager.default.fileExists(atPath: noteURL.path) && !FileManager.default.fileExists(atPath: assetURL.path) {
                        name = candidate
                        break
                    }
                    suffix += 1
                }
                log.info("同名笔记来源不同，另存为 \(name)", category: record.categoryName)
            }
        } else if FileManager.default.fileExists(atPath: assetURL.path) {
            // 同名附件已存在但笔记不存在：直接覆盖附件文件即可。
        }

        do {
            if FileManager.default.fileExists(atPath: assetURL.path) {
                try FileManager.default.removeItem(at: assetURL)
            }
            try FileManager.default.copyItem(at: attachmentFile, to: assetURL)
        } catch {
            throw ObsidianError.writeFailed(error.localizedDescription)
        }

        let note = Self.noteContent(record: record, attachmentName: assetURL.lastPathComponent, assetsFolder: config.assetsFolder.isEmpty ? "assets" : config.assetsFolder, tags: config.tags)
        do {
            try note.write(to: noteURL, atomically: true, encoding: .utf8)
        } catch {
            throw ObsidianError.writeFailed(error.localizedDescription)
        }
        return .written
    }

    func writePageText(record: CollectedRecord, forceFull: Bool, md5: String) throws -> ObsidianOutcome {
        let root = URL(fileURLWithPath: AppPaths.expand(config.vaultPath), isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ObsidianError.invalidVault
        }

        let notesDir = root.appendingPathComponent(config.notesFolder.isEmpty ? "网页采集笔记" : config.notesFolder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        } catch {
            throw ObsidianError.writeFailed(error.localizedDescription)
        }

        let rawTitle = record.pageTitle.trimmed.isEmpty ? "未命名页面" : record.pageTitle
        let baseName = FileUtil.sanitizeFileName(rawTitle)
        var name = baseName
        var noteURL = notesDir.appendingPathComponent(name + ".md")
        var suffix = 2

        if FileManager.default.fileExists(atPath: noteURL.path) {
            let existingSource = Self.sourceAddress(ofNoteAt: noteURL)
            let sameSource = existingSource.map { Address.normalize($0) == Address.normalize(record.pageURL) } ?? false
            let existingType = Self.noteType(ofNoteAt: noteURL)
            if !(sameSource && existingType == "正文") {
                while true {
                    let candidate = "\(baseName)-\(suffix)"
                    noteURL = notesDir.appendingPathComponent(candidate + ".md")
                    if !FileManager.default.fileExists(atPath: noteURL.path) {
                        name = candidate
                        break
                    }
                    suffix += 1
                }
                log.info("同名笔记来源不同，另存为 \(name)", category: record.categoryName)
            }
        }

        let note = Self.pageNoteContent(record: record, pageText: record.pageText, tags: config.tags)
        do {
            try note.write(to: noteURL, atomically: true, encoding: .utf8)
        } catch {
            throw ObsidianError.writeFailed(error.localizedDescription)
        }
        return .written
    }

    static func sourceAddress(ofNoteAt url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let line = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("来源地址:") }) else { return nil }
        var value = line.replacingOccurrences(of: "来源地址:", with: "").trimmed
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    static func noteType(ofNoteAt url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let line = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("类型:") }) else { return nil }
        var value = line.replacingOccurrences(of: "类型:", with: "").trimmed
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    static func noteContent(record: CollectedRecord, attachmentName: String, assetsFolder: String, tags: String) -> String {
        let tagList = tags.components(separatedBy: ",").map { $0.trimmed }.filter { !$0.isEmpty }
        var lines: [String] = []
        lines.append("---")
        lines.append("标题: \(yaml(record.pageTitle))")
        lines.append("来源地址: \(yaml(record.pageURL))")
        lines.append("分类: \(yaml(record.categoryName))")
        lines.append("类型: \"附件\"")
        lines.append("采集时间: \(yaml(record.collectedAt))")
        if tagList.isEmpty {
            lines.append("标签: []")
        } else {
            lines.append("标签:")
            for tag in tagList { lines.append("  - \(yaml(tag))") }
        }
        lines.append("附件文件名: \(yaml(attachmentName))")
        lines.append("---")
        lines.append("")
        lines.append("## 源页面链接")
        lines.append("")
        lines.append("[\(record.pageTitle)](\(record.pageURL))")
        lines.append("")
        lines.append("## 附件")
        lines.append("")
        lines.append("![[\(assetsFolder)/\(attachmentName)]]")
        lines.append("")
        lines.append("## 附件识别内容")
        lines.append("")
        lines.append(record.content)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func pageNoteContent(record: CollectedRecord, pageText: String, tags: String) -> String {
        let tagList = tags.components(separatedBy: ",").map { $0.trimmed }.filter { !$0.isEmpty }
        let linkText = record.pageTitle.trimmed.isEmpty ? record.pageURL : record.pageTitle
        var lines: [String] = []
        lines.append("---")
        lines.append("标题: \(yaml(record.pageTitle))")
        lines.append("来源地址: \(yaml(record.pageURL))")
        lines.append("分类: \(yaml(record.categoryName))")
        lines.append("类型: \"正文\"")
        lines.append("采集时间: \(yaml(record.collectedAt))")
        if tagList.isEmpty {
            lines.append("标签: []")
        } else {
            lines.append("标签:")
            for tag in tagList { lines.append("  - \(yaml(tag))") }
        }
        lines.append("---")
        lines.append("")
        lines.append("## 源页面链接")
        lines.append("")
        lines.append("[\(linkText)](\(record.pageURL))")
        lines.append("")
        lines.append("## 页面正文")
        lines.append("")
        lines.append(pageText)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func yaml(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\"\(escaped)\""
    }
}
