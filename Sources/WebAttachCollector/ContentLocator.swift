import Foundation
import WebKit

// MARK: - 正文定位计划

struct ContentPlan: Codable {
    var host: String
    var pattern: String
    var content: [String]
    var exclude: [String]
    var model: String
    var promptVersion: String
    var updatedAt: String
}

final class ContentPlanStore {
    static let promptVersion = "m14-locator-v3"

    private let fileURL: URL
    private var plans: [String: ContentPlan] = [:]

    init(fileURL: URL = AppPaths.appSupport.appendingPathComponent("content-plans.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([String: ContentPlan].self, from: data) {
            plans = loaded
        }
    }

    func plan(for url: URL) -> ContentPlan? {
        plans[Self.key(for: url)]
    }

    func save(_ plan: ContentPlan) {
        plans[Self.key(host: plan.host, pattern: plan.pattern)] = plan
        guard let data = try? JSONEncoder().encode(plans) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: AppPaths.appSupport.appendingPathComponent("content-plans.json"))
    }

    static func key(for url: URL) -> String {
        key(host: (url.host ?? "").lowercased(), pattern: pattern(for: url))
    }

    private static func key(host: String, pattern: String) -> String {
        host + "|" + pattern
    }

    /// 把路径中的数字段替换为 *，让同一栏目的详情页共用一份选择器。
    static func pattern(for url: URL) -> String {
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        let normalized = components.map { component -> String in
            let text = String(component).lowercased()
            let numeric = text.allSatisfy { $0.isNumber }
            let hexLike = text.count >= 6 && text.allSatisfy { $0.isHexDigit }
            return (numeric || hexLike) ? "*" : text
        }
        return "/" + normalized.joined(separator: "/")
    }
}

// MARK: - 模型定位与选择器提取

final class ContentLocator {
    private let config: SmartConfig
    private let apiKey: String
    private let log: LogStore
    private let http: HTTPClient
    private let store = ContentPlanStore()
    private var failedKeys = Set<String>()
    @MainActor private static var sharedExtractor: SelectorTextExtractor?

    init(config: SmartConfig, apiKey: String, log: LogStore) {
        self.config = config
        self.apiKey = apiKey
        self.log = log
        self.http = HTTPClient(
            userAgent: ConfigDefaults.userAgent,
            timeout: 20,
            limiter: RequestLimiter(),
            interval: { 0 }
        )
    }

    func close() {
        http.invalidate()
    }

    func cachedPlan(for url: URL) -> ContentPlan? {
        guard let plan = store.plan(for: url),
              plan.promptVersion == ContentPlanStore.promptVersion else { return nil }
        return plan
    }

    /// 仅在默认规则质量不佳时调用模型；同一模板失败一次后不再重试。
    func learn(for page: ParsedPage, html: String, reason: String) async -> ContentPlan? {
        let key = ContentPlanStore.key(for: page.finalURL)
        guard !failedKeys.contains(key) else { return nil }
        let outline = HTML.outline(html, maxChars: min(config.maxInputChars, 12000))
        guard !outline.isEmpty else { return nil }

        let prompt = buildPrompt(page: page, outline: outline)
        let started = Date()
        var parsed: (content: [String], exclude: [String])?
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                parsed = try await callModel(prompt: prompt)
                break
            } catch {
                lastError = error
                let message = error.localizedDescription
                if message.contains("401") || message.contains("403") { break }
                if attempt == 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
            }
        }
        if let content = parsed {
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let plan = ContentPlan(
                host: (page.finalURL.host ?? "").lowercased(),
                pattern: ContentPlanStore.pattern(for: page.finalURL),
                content: content.content,
                exclude: content.exclude,
                model: config.model,
                promptVersion: ContentPlanStore.promptVersion,
                updatedAt: TimeFormat.string()
            )
            if !plan.content.isEmpty {
                store.save(plan)
                log.smart("正文定位：模型给出 \(plan.content.joined(separator: ", ")) | 原因：\(reason) | 耗时：\(elapsed) ms | 模型：\(config.model)")
                return plan
            }
            failedKeys.insert(key)
            log.smart("正文定位：模型未给出可靠选择器，已回退默认规则")
            return nil
        }
        failedKeys.insert(key)
        log.smart("正文定位调用失败，已回退默认规则：\(lastError?.localizedDescription ?? "未知错误")")
        return nil
    }

    func extract(html: String, plan: ContentPlan) async -> String? {
        let extractor = await MainActor.run { () -> SelectorTextExtractor in
            if let existing = Self.sharedExtractor { return existing }
            let created = SelectorTextExtractor()
            Self.sharedExtractor = created
            return created
        }
        return await extractor.extract(html: html, content: plan.content, exclude: plan.exclude)
    }

    private func buildPrompt(page: ParsedPage, outline: String) -> String {
        var lines: [String] = [
            "你是网页正文定位器。只输出 JSON，不要解释，也不要思考。",
            #"输出格式：{"content":["CSS选择器"],"exclude":["CSS选择器"]}"#,
            "要求：",
            "1. content 只选承载主体内容的最小容器（正文区或新闻列表），最多 3 个，优先使用 id 或 class，避免 :nth-child 等伪类；",
            "2. 顶部导航、面包屑（含“当前位置”）、子栏目菜单、页脚一律不得放入 content；",
            "3. 主体是列表时，选包含列表项的 ul/ol 或其唯一父容器，不要连同外层栏目菜单一起选；",
            "4. exclude 必须清掉 content 内部残留的噪声：评论区（“发表评论/网友评论/共N条评论/畅言/文明上网理性发言”等）、相关推荐与热门推荐、延伸阅读、分享与点赞按钮、版权声明，最多 3 条，选择器尽量简短；",
            "5. 如果 content 容器里包含评论或推荐模块，要在 exclude 中写出对应选择器（常见 class 为 comment/pl/related/recommend/share 等）；",
            "6. 找不到可靠选择器时输出 {\"content\":[],\"exclude\":[]}；",
            "7. 不要输出正文文本，也不要输出解释。",
            "页面地址：\(page.finalURL.absoluteString)",
            "页面标题：\(page.title)"
        ]
        lines.append("DOM 骨架：")
        lines.append(outline)
        return lines.joined(separator: "\n")
    }

    private func callModel(prompt: String) async throws -> (content: [String], exclude: [String]) {
        guard let url = config.chatCompletionsURL else {
            throw NetworkError.siteRefused("服务地址无效")
        }
        let payload: [String: Any] = [
            "model": config.model,
            "temperature": 0,
            "max_tokens": 600,
            "stream": false,
            "enable_thinking": false,
            "messages": [["role": "user", "content": prompt]]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let result = try await http.postJSON(url, body: body, extraHeaders: ["Authorization": "Bearer \(apiKey)"])
        guard result.status < 400 else {
            throw NetworkError.badStatus(result.status, url.absoluteString)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw NetworkError.siteRefused("响应结构缺少 choices.message.content")
        }
        guard let start = text.firstIndex(of: "{") else {
            throw NetworkError.siteRefused("响应无 JSON：\(text.prefix(200))")
        }
        let jsonText: String
        if let end = text.lastIndex(of: "}"), end > start {
            jsonText = String(text[start...end])
        } else {
            jsonText = String(text[start...])
        }
        if let data = jsonText.data(using: .utf8),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let content = validSelectors(parsed["content"] as? [String] ?? [], limit: 3)
            let exclude = validSelectors(parsed["exclude"] as? [String] ?? [], limit: 5)
            return (content, exclude)
        }
        // 模型输出被截断时，直接从数组字面量里取已完整的部分。
        let content = selectorArray(key: "content", in: jsonText)
        guard !content.isEmpty else {
            throw NetworkError.siteRefused("响应格式非法：\(jsonText.prefix(160))")
        }
        return (validSelectors(content, limit: 3), validSelectors(selectorArray(key: "exclude", in: jsonText), limit: 5))
    }

    private func selectorArray(key: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\"\(key)\"\\s*:\\s*\\[([^\\]]*)\\]", options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return [] }
        return String(text[range]).components(separatedBy: "\"")
            .enumerated().filter { $0.offset % 2 == 1 }.map { $0.element }
    }

    private func validSelectors(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in values {
            let value = raw.trimmed
            guard !value.isEmpty, value.count <= 120 else { continue }
            guard !value.contains("<"), !value.contains(">"), !value.contains("{"), !value.contains("}") else { continue }
            guard seen.insert(value).inserted else { continue }
            result.append(value)
            if result.count >= limit { break }
        }
        return result
    }
}

// MARK: - 离线 HTML 选择器提取

@MainActor
final class SelectorTextExtractor: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<String?, Never>?
    private var webView: WKWebView?
    private var finished = false
    private let timeout: Double = 10
    private var contentJSON = "[]"
    private var excludeJSON = "[]"

    @MainActor private static var sharedInstance: SelectorTextExtractor?

    /// 供采集方案与正文定位共用；调用方需保证串行执行。
    @MainActor
    static func shared() -> SelectorTextExtractor {
        if let sharedInstance { return sharedInstance }
        let created = SelectorTextExtractor()
        sharedInstance = created
        return created
    }

    func extract(html: String, content: [String], exclude: [String]) async -> String? {
        guard !content.isEmpty else { return nil }
        finished = false
        contentJSON = Self.json(content)
        excludeJSON = Self.json(exclude)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // 离线提取只读 DOM，不执行页面脚本，避免脚本改写或移除正文节点。
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        view.navigationDelegate = self
        webView = view

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            view.loadHTMLString(html, baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(nil)
            }
        }
    }

    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        webView?.navigationDelegate = nil
        webView = nil
        continuation?.resume(returning: value)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = Self.script(content: contentJSON, exclude: excludeJSON)
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            Task { @MainActor in
                let raw = (value as? String)?.trimmed ?? ""
                self?.finish(Self.bestCandidate(from: raw))
            }
        }
    }

    /// 模型可能把导航和正文一起选中：逐块取文，丢弃过短块，优先选无导航噪声的最长块。
    private static func bestCandidate(from raw: String) -> String? {
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [String] else {
            return nil
        }
        let texts = list.map { HTML.trimTrailingNoise($0.trimmed) }.filter { !$0.isEmpty }
        guard !texts.isEmpty else { return nil }
        let usable = texts.filter { $0.count >= 200 }
        let pool = usable.isEmpty ? texts.filter { $0.count >= 30 } : usable
        guard !pool.isEmpty else { return nil }
        let clean = pool.filter { !HTML.contentQuality($0).poor }
        return (clean.isEmpty ? pool : clean).max { $0.count < $1.count }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    private static func json(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private static func script(content: String, exclude: String) -> String {
        """
        (function(){
          var contents = \(content), excludes = \(exclude);
          var nodes = [];
          for (var i = 0; i < contents.length; i++) {
            try {
              var found = document.querySelectorAll(contents[i]);
              for (var j = 0; j < found.length; j++) nodes.push(found[j]);
            } catch (e) {}
          }
          var unique = [];
          for (var k = 0; k < nodes.length; k++) {
            if (unique.indexOf(nodes[k]) === -1) unique.push(nodes[k]);
          }
          function plain(node) {
            var out = [];
            (function walk(n) {
              if (n.nodeType === 3) { out.push(n.nodeValue); return; }
              if (n.nodeType !== 1) return;
              var tag = n.tagName.toLowerCase();
              if (tag === "br") { out.push("\\n"); return; }
              var block = /^(p|div|li|tr|h[1-6]|section|article|ul|ol|table|td|th|dd|dt|blockquote|pre|header|footer|nav|main)$/.test(tag);
              if (block) out.push("\\n");
              for (var i = 0; i < n.childNodes.length; i++) walk(n.childNodes[i]);
              if (block) out.push("\\n");
            })(node);
            return out.join("");
          }
          function tidy(s) {
            var lines = s.replace(/\\u00a0/g, " ").split("\\n");
            var out = [];
            for (var i = 0; i < lines.length; i++) {
              var line = lines[i].replace(/[ \\t]+/g, " ").trim();
              if (!line) {
                if (out.length && out[out.length - 1] !== "") out.push("");
                continue;
              }
              out.push(line);
            }
            return out.join("\\n").trim();
          }
          var parts = [];
          for (var m = 0; m < unique.length; m++) {
            var clone = unique[m].cloneNode(true);
            var noise = clone.querySelectorAll("script,style,noscript,[hidden],[style*='display:none'],[style*='display: none']");
            for (var s = noise.length - 1; s >= 0; s--) noise[s].parentNode.removeChild(noise[s]);
            var total = (clone.textContent || "").length;
            for (var n = 0; n < excludes.length; n++) {
              try {
                var bad = clone.querySelectorAll(excludes[n]);
                var removed = 0;
                for (var r = 0; r < bad.length; r++) removed += (bad[r].textContent || "").length;
                // 模型误把正文容器放进 exclude 时会让结果几乎为空，这类规则直接忽略。
                if (total > 0 && removed > total * 0.35) continue;
                for (var p = bad.length - 1; p >= 0; p--) bad[p].parentNode.removeChild(bad[p]);
              } catch (e) {}
            }
            var inner = tidy(clone.innerText || "");
            var full = tidy(plain(clone));
            var text = full.length > inner.length ? full : inner;
            if (text) parts.push(text);
          }
          return JSON.stringify(parts);
        })()
        """
    }
}
