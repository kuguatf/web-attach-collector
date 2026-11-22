import Foundation
import CryptoKit
import SQLite3

struct SmartItem {
    let key: String
    let pageNormalized: String
    let pageTitle: String
    let fileName: String
    let candidates: [CategoryConfig]
}

struct SmartMetrics {
    var calls = 0
    var cacheHits = 0
    var fallbacks = 0
    var budgetExhausted = false
    var stopped = false
}

final class SmartJudge {
    private let config: SmartConfig
    private let apiKey: String
    private let allCategories: [CategoryConfig]
    private let log: LogStore
    private let http: HTTPClient
    private var cache: SQLiteDB?
    private(set) var metrics = SmartMetrics()
    private var budgetLogged = false

    init(config: SmartConfig, apiKey: String, allCategories: [CategoryConfig], log: LogStore) {
        self.config = config
        self.apiKey = apiKey
        self.allCategories = allCategories
        self.log = log
        let limiter = RequestLimiter()
        self.http = HTTPClient(userAgent: ConfigDefaults.userAgent, timeout: 10, limiter: limiter, interval: { 0 })
        openCache()
    }

    private func openCache() {
        do {
            let db = try SQLiteDB(path: AppPaths.smartCacheDB.path)
            try db.exec("""
            CREATE TABLE IF NOT EXISTS 智能缓存 (
                key_hash TEXT PRIMARY KEY,
                分类标识 TEXT,
                分类名称 TEXT,
                来源 TEXT,
                模型 TEXT,
                提示版本 TEXT,
                时间 TEXT
            );
            """)
            cache = db
        } catch {
            cache = nil
        }
    }

    func close() {
        cache?.close()
        cache = nil
        http.invalidate()
    }

    static func cacheCount() -> Int {
        guard let db = try? SQLiteDB(path: AppPaths.smartCacheDB.path),
              let statement = try? db.prepare("SELECT COUNT(*) FROM 智能缓存;") else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(db.int(statement, 0))
    }

    static func clearCache() {
        guard let db = try? SQLiteDB(path: AppPaths.smartCacheDB.path) else { return }
        try? db.exec("DELETE FROM 智能缓存;")
        db.close()
    }

    static func makeKey(model: String, version: String, page: String, fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let raw = "\(model)|\(version)|\(page)|\(fileName.lowercased())|\(ext)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 返回 key -> 分类标识（nil 表示按规则回退）。
    func resolve(items: [SmartItem]) async -> [String: UUID?] {
        var result: [String: UUID?] = [:]
        var pending: [SmartItem] = []
        var pendingByKey: [String: SmartItem] = [:]

        for item in items {
            if let cached = cachedCategory(for: item) {
                metrics.cacheHits += 1
                result[item.key] = cached
                log.smart("附件「\(item.fileName)」→ 分类「\(allCategories.first { $0.id == cached }?.name ?? "")」 | 来源：缓存 | 模型：\(config.model)")
                continue
            }
            if pendingByKey[item.key] == nil {
                pendingByKey[item.key] = item
                pending.append(item)
            }
        }

        var index = 0
        while index < pending.count {
            var batch: [SmartItem] = []
            var prompt = ""
            while index < pending.count && batch.count < max(5, min(20, config.batchSize)) {
                let candidate = pending[index]
                let trial = batch + [candidate]
                let trialPrompt = buildPrompt(trial)
                if !batch.isEmpty && trialPrompt.count > config.maxInputChars { break }
                batch = trial
                prompt = trialPrompt
                index += 1
                if prompt.count >= config.maxInputChars { break }
            }
            guard !batch.isEmpty else { break }

            if metrics.stopped || metrics.calls >= config.maxCalls {
                if !budgetLogged {
                    budgetLogged = true
                    metrics.budgetExhausted = true
                    log.smart("智能判定预算已用完，后续按规则处理")
                }
                for item in batch {
                    metrics.fallbacks += 1
                    cachePut(item: item, category: item.candidates.first, source: "规则回退(预算)")
                    result[item.key] = item.candidates.first?.id
                }
                continue
            }

            let start = Date()
            metrics.calls += 1
            do {
                let (found, reasoningTokens) = try await callModel(prompt: prompt, batch: batch)
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                for (offset, item) in batch.enumerated() {
                    let indexKey = offset + 1
                    let categoryID = found[indexKey]
                    if let categoryID = categoryID, item.candidates.contains(where: { $0.id == categoryID }) {
                        cachePut(item: item, category: item.candidates.first { $0.id == categoryID }, source: "AI")
                        result[item.key] = categoryID
                        let name = item.candidates.first { $0.id == categoryID }?.name ?? ""
                        log.smart("附件「\(item.fileName)」→ 分类「\(name)」 | 来源：AI | 耗时：\(elapsed) ms | 模型：\(config.model) | 思考：关闭 | reasoning_tokens：\(reasoningTokens)")
                    } else {
                        metrics.fallbacks += 1
                        let fallback = item.candidates.first
                        cachePut(item: item, category: fallback, source: "规则回退(非法)")
                        result[item.key] = fallback?.id
                        log.smart("附件「\(item.fileName)」→ 规则回退 | 来源：规则回退 | 耗时：\(elapsed) ms | 模型：\(config.model) | 思考：关闭 | reasoning_tokens：\(reasoningTokens)")
                    }
                }
            } catch {
                let message = error.localizedDescription
                if message.contains("401") || message.contains("403") {
                    metrics.stopped = true
                }
                for item in batch {
                    metrics.fallbacks += 1
                    let fallback = item.candidates.first
                    cachePut(item: item, category: fallback, source: "规则回退(失败)")
                    result[item.key] = fallback?.id
                }
                log.smart("智能判定调用失败，已回退规则：\(message)")
            }
        }

        return result
    }

    private func callModel(prompt: String, batch: [SmartItem]) async throws -> ([Int: UUID], Int) {
        guard let url = config.chatCompletionsURL else {
            throw FeishuError(message: "服务地址无效")
        }
        let payload: [String: Any] = [
            "model": config.model,
            "temperature": 0,
            "max_tokens": 400,
            "stream": false,
            "enable_thinking": false,
            "messages": [["role": "user", "content": prompt]]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let result = try await http.postJSON(url, body: body, extraHeaders: ["Authorization": "Bearer \(apiKey)"])
        if result.status == 401 || result.status == 403 {
            throw FeishuError(message: "HTTP \(result.status)")
        }
        guard result.status < 400 else {
            throw FeishuError(message: "HTTP \(result.status)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmed.isEmpty else {
            throw FeishuError(message: "响应无正文")
        }
        var reasoningTokens = 0
        if let usage = json["usage"] as? [String: Any] {
            if let details = usage["completion_tokens_details"] as? [String: Any], let value = details["reasoning_tokens"] as? Int {
                reasoningTokens = value
            } else if let value = usage["reasoning_tokens"] as? Int {
                reasoningTokens = value
            }
        }
        if reasoningTokens > 0 {
            throw FeishuError(message: "模型仍在思考模式（reasoning_tokens=\(reasoningTokens)）")
        }
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}") else {
            throw FeishuError(message: "响应中没有 JSON")
        }
        let jsonText = String(content[start...end])
        guard let data = jsonText.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = parsed["results"] as? [[String: Any]] else {
            throw FeishuError(message: "响应格式非法")
        }
        var mapping: [Int: UUID] = [:]
        for row in rows {
            guard let i = row["i"] as? Int, i >= 1, i <= batch.count else { continue }
            if let idText = row["category_id"] as? String, let id = UUID(uuidString: idText) {
                mapping[i] = id
            }
        }
        return (mapping, reasoningTokens)
    }

    private func buildPrompt(_ batch: [SmartItem]) -> String {
        var ids: [UUID] = []
        var byID: [UUID: CategoryConfig] = [:]
        for item in batch {
            for category in item.candidates where byID[category.id] == nil {
                byID[category.id] = category
                ids.append(category.id)
            }
        }
        var lines: [String] = [
            "你是附件分类器。只输出 JSON，不要解释，也不要思考。",
            "输出格式：{\"results\":[{\"i\":1,\"category_id\":\"分类标识\"}]}；无法判断用 null。",
            "只能从每个附件给出的候选分类中选择。",
            "每个附件独立判断，不要参考同批其他附件的分类结果。",
            "如果文件名和页面标题不足以判断，category_id 用 null，不要猜测。",
            "候选分类："
        ]
        for id in ids {
            guard let category = byID[id] else { continue }
            let keywords = category.attachmentKeywordList.prefix(10).joined(separator: ",")
            lines.append("- \(id.uuidString) | \(category.name) | 关键词：\(keywords)")
        }
        lines.append("附件：")
        for (offset, item) in batch.enumerated() {
            let name = String(item.fileName.prefix(200))
            let title = String(item.pageTitle.prefix(200))
            let candidates = item.candidates.map { $0.id.uuidString }.joined(separator: ",")
            lines.append("\(offset + 1). 文件名：\(name) | 页面标题：\(title) | 候选：\(candidates)")
        }
        return lines.joined(separator: "\n")
    }

    private func cachedCategory(for item: SmartItem) -> UUID? {
        guard let cache = cache,
              let statement = try? cache.prepare("SELECT 分类标识 FROM 智能缓存 WHERE key_hash = ? LIMIT 1;") else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        cache.bindText(statement, 1, item.key)
        guard sqlite3_step(statement) == SQLITE_ROW, let value = cache.text(statement, 0), let id = UUID(uuidString: value) else {
            return nil
        }
        guard let category = allCategories.first(where: { $0.id == id }), category.enabled,
              item.candidates.contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }

    private func cachePut(item: SmartItem, category: CategoryConfig?, source: String) {
        guard let cache = cache, let category = category else { return }
        let sql = """
        INSERT INTO 智能缓存 (key_hash, 分类标识, 分类名称, 来源, 模型, 提示版本, 时间)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(key_hash) DO UPDATE SET
            分类标识 = excluded.分类标识,
            分类名称 = excluded.分类名称,
            来源 = excluded.来源,
            模型 = excluded.模型,
            提示版本 = excluded.提示版本,
            时间 = excluded.时间;
        """
        guard let statement = try? cache.prepare(sql) else { return }
        cache.bindText(statement, 1, item.key)
        cache.bindText(statement, 2, category.id.uuidString)
        cache.bindText(statement, 3, category.name)
        cache.bindText(statement, 4, source)
        cache.bindText(statement, 5, config.model)
        cache.bindText(statement, 6, config.promptVersion)
        cache.bindText(statement, 7, TimeFormat.string())
        try? cache.stepDone(statement)
        sqlite3_finalize(statement)
    }
}
