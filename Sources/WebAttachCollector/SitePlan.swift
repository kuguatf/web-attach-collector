import Foundation
import WebKit

// MARK: - 方案缓存

final class SitePlanStore {
    static let version = "site-plan-v1"
    static let promptVersion = "site-v1"

    private let fileURL: URL
    private(set) var plans: [String: SitePlan] = [:]

    init(fileURL: URL = AppPaths.appSupport.appendingPathComponent("site-plans.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([String: SitePlan].self, from: data) {
            plans = loaded
        }
    }

    /// 只有版本一致且已确认的方案才可执行。
    func plan(for url: URL) -> SitePlan? {
        guard let plan = plans[Self.key(for: url)],
              plan.version == Self.version,
              plan.meta.promptVersion == Self.promptVersion,
              plan.meta.confirmed,
              !plan.list.item.trimmed.isEmpty else { return nil }
        return plan
    }

    /// 供界面回显：不要求已确认。
    func stored(for url: URL) -> SitePlan? {
        guard let plan = plans[Self.key(for: url)], plan.version == Self.version else { return nil }
        return plan
    }

    func save(_ plan: SitePlan) {
        plans[Self.key(host: plan.host, pattern: plan.pathPattern)] = plan
        guard let data = try? JSONEncoder().encode(plans) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    func remove(for url: URL) {
        plans.removeValue(forKey: Self.key(for: url))
        guard let data = try? JSONEncoder().encode(plans) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: AppPaths.appSupport.appendingPathComponent("site-plans.json"))
    }

    static func key(for url: URL) -> String {
        key(host: (url.host ?? "").lowercased(), pattern: ContentPlanStore.pattern(for: url))
    }

    private static func key(host: String, pattern: String) -> String {
        host + "|" + pattern
    }
}

// MARK: - 解析结果

struct SitePlanListItem {
    var title: String = ""
    var url: String = ""
    var date: String = ""
}

struct SitePlanPreviewItem: Identifiable {
    let id = UUID()
    var index: Int
    var title: String
    var date: String
    var url: String
    var attachment: String
}

struct SitePlanPreview {
    var items: [SitePlanPreviewItem] = []
    var contentPreview: String = ""
    var contentChars: Int = 0
    var elapsed: Double = 0
    var usedModel: Bool = false
    var model: String = ""
    var message: String = ""
    var listCount: Int = 0
}

struct SitePlanValidation {
    var listCount = 0
    var titleHits = 0
    var urlHits = 0
    var contentChars = 0
    var contentPoor = false
    var nextPageFound = false
    var problems: [String] = []

    /// 设计稿验收阈值：前 3 条 url 全非空、title ≥2、正文 ≥30 字。
    var passed: Bool {
        listCount >= 3 && urlHits >= 3 && titleHits >= 2 && contentChars >= 30
    }

    /// 规则探测是否已足够好，无需调用模型。
    var ruleGrade: Bool {
        passed && !contentPoor && contentChars >= 120
    }
}

struct SitePlanGenerationResult {
    var plan: SitePlan?
    var validation = SitePlanValidation()
    var preview = SitePlanPreview()
    var error: String?
}

private struct SitePlanProbe {
    var item = ""
    var count = 0
    var title = "a"
    var date = ""
    var paging: SitePagingPlan?
}

// MARK: - 离线 DOM 探测与提取

enum SitePlanExtractor {
    static func baseURL(html: String, pageURL: URL) -> URL {
        HTML.baseHref(html).flatMap { URL(string: $0, relativeTo: pageURL)?.absoluteURL } ?? pageURL
    }

    static func listItems(html: String, base: URL, plan: SitePlan) async -> [SitePlanListItem] {
        let itemSelector = plan.list.item.trimmed
        guard !itemSelector.isEmpty else { return [] }
        let script = SitePlanJS.extractList(
            item: itemSelector,
            title: plan.list.fields.title,
            url: plan.list.fields.url,
            date: plan.list.fields.date
        )
        let raw = await SitePlanBrowser.evaluate(html: html, baseURL: base, script: script)
        guard let raw = raw,
              let object = jsonObject(raw),
              let rows = object["items"] as? [[String: Any]] else { return [] }
        return rows.map { row in
            var item = SitePlanListItem()
            item.title = value(row["title"], field: plan.list.fields.title)
            item.date = value(row["date"], field: plan.list.fields.date)
            let rawURL = value(row["url"], field: plan.list.fields.url)
            if !rawURL.isEmpty, let url = Address.resolve(rawURL, base: base) {
                item.url = url.absoluteString
            }
            return item
        }
    }

    static func nextPageURL(html: String, base: URL, paging: SitePagingPlan) async -> (url: URL, label: String)? {
        guard paging.type == .link, !paging.selector.trimmed.isEmpty else { return nil }
        let script = SitePlanJS.nextPage(selector: paging.selector, urlFrom: paging.urlFrom.rawValue)
        guard let raw = await SitePlanBrowser.evaluate(html: html, baseURL: base, script: script),
              let object = jsonObject(raw),
              object["found"] as? Bool == true,
              let value = object["raw"] as? String, !value.trimmed.isEmpty,
              let url = Address.resolve(value, base: base) else { return nil }
        return (url, object["text"] as? String ?? "")
    }

    static func templateURL(paging: SitePagingPlan, pageNumber: Int, base: URL) -> URL? {
        guard paging.type == .template, !paging.template.trimmed.isEmpty else { return nil }
        let text = paging.template.replacingOccurrences(of: "{page}", with: "\(pageNumber)")
        return Address.resolve(text, base: base)
    }

    static func paramURL(paging: SitePagingPlan, pageNumber: Int, base: URL) -> URL? {
        guard paging.type == .param,
              let resolved = Address.resolve(paging.param.base, base: base),
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == paging.param.name }
        items.append(URLQueryItem(name: paging.param.name, value: "\(pageNumber)"))
        components.queryItems = items
        return components.url
    }

    static func attachmentURLs(html: String, base: URL, selector: String) async -> [URL] {
        let script = SitePlanJS.attachmentURLs(selector: selector)
        guard let raw = await SitePlanBrowser.evaluate(html: html, baseURL: base, script: script),
              let object = jsonObject(raw),
              let values = object["urls"] as? [String] else { return [] }
        var seen = Set<String>()
        var result: [URL] = []
        for value in values {
            guard let url = Address.resolve(value, base: base) else { continue }
            let key = Address.normalize(url.absoluteString)
            if seen.insert(key).inserted { result.append(url) }
        }
        return result
    }

    static func contentText(html: String, content: [String], exclude: [String], fallback: String) async -> String {
        guard !content.isEmpty else { return fallback.trimmed }
        let extractor = await MainActor.run { SelectorTextExtractor.shared() }
        if let text = await extractor.extract(html: html, content: content, exclude: exclude), text.count >= 30 {
            return text
        }
        return fallback.trimmed
    }

    static func filterAttachments(_ list: [RawAttachment], plan: SitePlan) -> [RawAttachment] {
        let extensions = Set(plan.attachments.extensions.map { $0.trimmed.lowercased() }.filter { !$0.isEmpty })
        guard !extensions.isEmpty else { return list }
        return list.filter { extensions.contains($0.url.pathExtension.lowercased()) }
    }

    static func jsonObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func value(_ raw: Any?, field: SiteField) -> String {
        var value = ""
        if let text = raw as? String {
            value = text
        } else if let raw = raw, !(raw is NSNull) {
            value = String(describing: raw)
        }
        if !field.regex.trimmed.isEmpty {
            value = capture(value, pattern: field.regex)
        }
        return field.trim ? value.trimmed : value
    }

    private static func capture(_ value: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return "" }
        if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound,
           let range = Range(match.range(at: 1), in: value) {
            return String(value[range])
        }
        guard let range = Range(match.range(at: 0), in: value) else { return "" }
        return String(value[range])
    }
}

// MARK: - 方案生成

final class SitePlanGenerator {
    private let smart: SmartConfig
    private let apiKey: String?
    private let log: LogStore
    private let useDynamic: Bool
    private let http: HTTPClient

    init(smart: SmartConfig, apiKey: String?, log: LogStore, useDynamic: Bool) {
        self.smart = smart
        self.apiKey = apiKey
        self.log = log
        self.useDynamic = useDynamic
        self.http = HTTPClient(userAgent: ConfigDefaults.userAgent, timeout: 40, limiter: RequestLimiter(), interval: { 0 })
    }

    func close() {
        http.invalidate()
    }

    private var canUseModel: Bool {
        smart.chatCompletionsURL != nil && !smart.model.trimmed.isEmpty && !(apiKey ?? "").isEmpty
    }

    func generate(entry: URL, entryPage: ParsedPage, loader: PageLoader) async -> SitePlanGenerationResult {
        let started = Date()
        guard let html = entryPage.sourceHTML, !html.isEmpty else {
            var result = SitePlanGenerationResult()
            result.error = "页面未保留源码，无法分析页面结构"
            return result
        }
        let base = SitePlanExtractor.baseURL(html: html, pageURL: entryPage.finalURL)
        let probe = await Self.probe(html: html, base: base)
        var plan = planFromProbe(probe, entry: entryPage.finalURL)
        await applyDetailContent(to: &plan, entryPage: entryPage, loader: loader)
        var validation = await validate(plan: plan, entryPage: entryPage, loader: loader)
        var bestPlan = plan
        var bestValidation = validation
        var usedModel = false
        var lastError: String?

        if !validation.ruleGrade && canUseModel {
            for attempt in 0..<2 {
                do {
                    var candidate = bestPlan
                    let fragment = try await callModel(plan: candidate, probe: probe, page: entryPage, html: html, feedback: validation.problems.joined(separator: "；"))
                    usedModel = true
                    merge(fragment: fragment, into: &candidate)
                    let candidateValidation = await validate(plan: candidate, entryPage: entryPage, loader: loader)
                    if score(candidateValidation) > score(bestValidation) {
                        bestPlan = candidate
                        bestValidation = candidateValidation
                    } else if candidate.list.item != bestPlan.list.item {
                        // 模型可能改坏了原本可用的列表选择器：保留列表与翻页，仅采纳正文/附件改进。
                        var hybrid = bestPlan
                        hybrid.detail = candidate.detail
                        hybrid.attachments = candidate.attachments
                        if candidate.paging.type == .none || candidateValidation.nextPageFound {
                            hybrid.paging = candidate.paging
                        }
                        let hybridValidation = await validate(plan: hybrid, entryPage: entryPage, loader: loader)
                        if score(hybridValidation) > score(bestValidation) {
                            bestPlan = hybrid
                            bestValidation = hybridValidation
                        }
                    }
                    validation = candidateValidation
                    if bestValidation.ruleGrade { break }
                    if attempt == 0 {
                        log.smart("方案生成：首次校验未通过（\(candidateValidation.problems.joined(separator: "；"))），重试 1 次")
                    }
                } catch {
                    lastError = error.localizedDescription
                    if attempt == 0 {
                        log.smart("方案生成调用失败，重试 1 次：\(error.localizedDescription)")
                    }
                }
            }
            plan = bestPlan
            validation = bestValidation
        }

        guard validation.passed else {
            var result = SitePlanGenerationResult()
            result.validation = validation
            result.plan = probe.count >= 3 ? plan : nil
            let message = lastError ?? (validation.problems.isEmpty ? "未找到可靠的列表结构" : validation.problems.joined(separator: "；"))
            result.preview = SitePlanPreview(elapsed: Date().timeIntervalSince(started), usedModel: usedModel, model: smart.model, message: "未生成可靠方案")
            result.error = "未生成可靠方案：\(message)"
            log.smart("方案生成失败：\(message)")
            return result
        }

        var preview = await buildPreview(plan: plan, entryPage: entryPage, loader: loader)
        preview.elapsed = Date().timeIntervalSince(started)
        preview.usedModel = usedModel
        preview.model = usedModel ? smart.model : ""
        preview.listCount = validation.listCount
        let elapsedText = String(format: "%.1f", preview.elapsed)
        log.smart("方案生成：列表项=\(plan.list.item)，翻页=\(plan.paging.type.rawValue)，正文=\(plan.detail.content.joined(separator: ",")) | 耗时 \(elapsedText)s | 命中 \(validation.listCount) 条")
        return SitePlanGenerationResult(plan: plan, validation: validation, preview: preview, error: nil)
    }

    // MARK: 规则探测

    private static func probe(html: String, base: URL) async -> SitePlanProbe {
        var probe = SitePlanProbe()
        guard let raw = await SitePlanBrowser.evaluate(html: html, baseURL: base, script: SitePlanJS.probe()),
              let object = SitePlanExtractor.jsonObject(raw) else { return probe }
        probe.count = object["count"] as? Int ?? 0
        probe.item = (object["item"] as? String ?? "").trimmed
        probe.title = (object["title"] as? String ?? "a").trimmed
        probe.date = (object["date"] as? String ?? "").trimmed
        if let paging = object["paging"] as? [String: Any],
           let selector = (paging["selector"] as? String)?.trimmed, !selector.isEmpty {
            var value = SitePagingPlan()
            value.type = .link
            value.selector = selector
            value.urlFrom = (paging["urlFrom"] as? String) == "onclick" ? .onclick : .href
            value.maxPages = 20
            probe.paging = value
        }
        return probe
    }

    private static func probeContent(html: String, base: URL) async -> (content: [String], exclude: [String]) {
        guard let raw = await SitePlanBrowser.evaluate(html: html, baseURL: base, script: SitePlanJS.contentProbe()),
              let object = SitePlanExtractor.jsonObject(raw) else { return ([], []) }
        let content = cleanList(object["content"] as? [String] ?? [], limit: 3)
        let exclude = cleanList(object["exclude"] as? [String] ?? [], limit: 3)
        return (content, exclude)
    }

    /// 列表页结构不能代表正文，正文容器必须在详情页探测。
    private func applyDetailContent(to plan: inout SitePlan, entryPage: ParsedPage, loader: PageLoader) async {
        guard let html = entryPage.sourceHTML else { return }
        let base = SitePlanExtractor.baseURL(html: html, pageURL: entryPage.finalURL)
        let items = await SitePlanExtractor.listItems(html: html, base: base, plan: plan)
        guard let first = items.first(where: { !$0.url.trimmed.isEmpty }),
              let url = URL(string: first.url),
              let page = try? await loader.load(url, useDynamic: useDynamic, keepHTML: true),
              let detailHTML = page.sourceHTML, !detailHTML.isEmpty else { return }
        let detailBase = SitePlanExtractor.baseURL(html: detailHTML, pageURL: page.finalURL)
        let probed = await Self.probeContent(html: detailHTML, base: detailBase)
        if !probed.content.isEmpty { plan.detail.content = probed.content }
        if !probed.exclude.isEmpty { plan.detail.exclude = probed.exclude }
    }

    private func planFromProbe(_ probe: SitePlanProbe, entry: URL) -> SitePlan {
        var plan = SitePlan()
        plan.version = SitePlanStore.version
        plan.host = (entry.host ?? "").lowercased()
        plan.pathPattern = ContentPlanStore.pattern(for: entry)
        plan.entry = entry.absoluteString
        plan.list.item = probe.item
        plan.list.fields.title = SiteField(selector: probe.title.isEmpty ? "a" : probe.title)
        plan.list.fields.url = SiteField(selector: probe.title.isEmpty ? "a" : probe.title, attr: .href)
        plan.list.fields.date = SiteField(selector: probe.date)
        plan.paging = probe.paging ?? SitePagingPlan()
        plan.meta.model = ""
        plan.meta.promptVersion = SitePlanStore.promptVersion
        plan.meta.createdAt = TimeFormat.string()
        plan.meta.confirmed = false
        return plan
    }

    // MARK: 校验

    private func validate(plan: SitePlan, entryPage: ParsedPage, loader: PageLoader) async -> SitePlanValidation {
        var validation = SitePlanValidation()
        guard let html = entryPage.sourceHTML else {
            validation.problems.append("页面未保留源码")
            return validation
        }
        let base = SitePlanExtractor.baseURL(html: html, pageURL: entryPage.finalURL)
        let items = await SitePlanExtractor.listItems(html: html, base: base, plan: plan)
        validation.listCount = items.count
        let first = Array(items.prefix(3))
        validation.urlHits = first.filter { !$0.url.trimmed.isEmpty }.count
        validation.titleHits = first.filter { $0.title.trimmed.count >= 2 }.count
        if items.count < 3 { validation.problems.append("列表项只命中 \(items.count) 条") }
        if validation.urlHits < 3 { validation.problems.append("前 3 条链接不完整（\(validation.urlHits)/3）") }
        if validation.titleHits < 2 { validation.problems.append("前 3 条标题命中 \(validation.titleHits)/3") }

        if plan.paging.type == .link {
            validation.nextPageFound = await SitePlanExtractor.nextPageURL(html: html, base: base, paging: plan.paging) != nil
            if !validation.nextPageFound { validation.problems.append("未找到下一页元素") }
        }

        var content = entryPage.contentText
        var detailLoaded = false
        if let firstURL = first.first(where: { !$0.url.trimmed.isEmpty })?.url,
           let url = URL(string: firstURL) {
            do {
                let page = try await loader.load(url, useDynamic: useDynamic, keepHTML: true)
                detailLoaded = true
                content = await SitePlanExtractor.contentText(
                    html: page.sourceHTML ?? "",
                    content: plan.detail.content,
                    exclude: plan.detail.exclude,
                    fallback: page.contentText
                )
            } catch {
                validation.problems.append("详情页加载失败：\(error.localizedDescription)")
            }
        }
        validation.contentChars = content.trimmed.count
        if validation.contentChars < 30 {
            validation.problems.append("正文过短（\(validation.contentChars) 字）")
        } else {
            validation.contentPoor = HTML.contentQuality(content).poor
        }
        if !detailLoaded && plan.detail.content.isEmpty {
            validation.problems.append("未定位到详情页正文")
        }
        return validation
    }

    // MARK: 预览

    private func buildPreview(plan: SitePlan, entryPage: ParsedPage, loader: PageLoader) async -> SitePlanPreview {
        var preview = SitePlanPreview()
        guard let html = entryPage.sourceHTML else {
            preview.message = "页面未保留源码"
            return preview
        }
        let base = SitePlanExtractor.baseURL(html: html, pageURL: entryPage.finalURL)
        let items = await SitePlanExtractor.listItems(html: html, base: base, plan: plan)
        preview.listCount = items.count
        if items.isEmpty {
            preview.message = "列表项未命中"
            return preview
        }
        for (offset, item) in items.prefix(3).enumerated() {
            var row = SitePlanPreviewItem(index: offset + 1, title: item.title, date: item.date, url: item.url, attachment: "")
            if let url = URL(string: item.url) {
                if let page = try? await loader.load(url, useDynamic: useDynamic, keepHTML: true) {
                    let attachments = await planAttachments(plan: plan, page: page)
                    if attachments.isEmpty {
                        row.attachment = "—"
                    } else {
                        let first = attachments.first?.nameHint?.trimmed ?? attachments.first?.url.lastPathComponent ?? ""
                        row.attachment = attachments.count == 1
                            ? (first.isEmpty ? "1 个" : first)
                            : "\(attachments.count) 个 · \(String(first.prefix(18)))"
                    }
                    if offset == 0 {
                        let content = await SitePlanExtractor.contentText(
                            html: page.sourceHTML ?? "",
                            content: plan.detail.content,
                            exclude: plan.detail.exclude,
                            fallback: page.contentText
                        )
                        preview.contentChars = content.trimmed.count
                        preview.contentPreview = String(content.trimmed.prefix(200))
                    }
                }
            }
            preview.items.append(row)
        }
        return preview
    }

    private func planAttachments(plan: SitePlan, page: ParsedPage) async -> [RawAttachment] {
        let selector = plan.attachments.linkSelector.trimmed
        if !selector.isEmpty, selector != "a[href]", let html = page.sourceHTML {
            let base = SitePlanExtractor.baseURL(html: html, pageURL: page.finalURL)
            let urls = await SitePlanExtractor.attachmentURLs(html: html, base: base, selector: selector)
            let allowed = SitePlanExtractor.filterAttachments(
                urls.map { RawAttachment(url: $0, nameHint: nil, openStdHcno: nil) },
                plan: plan
            )
            if !allowed.isEmpty { return allowed }
        }
        return SitePlanExtractor.filterAttachments(page.attachments, plan: plan)
    }

    // MARK: 模型

    private struct PlanFragment: Decodable {
        struct ListFragment: Decodable {
            var item: String?
            var fields: FieldsFragment?
        }
        struct FieldsFragment: Decodable {
            var title: SiteField?
            var url: SiteField?
            var date: SiteField?
        }
        struct PagingFragment: Decodable {
            var type: String?
            var selector: String?
            var urlFrom: String?
            var template: String?
            var param: SiteParamPaging?
            var maxPages: Int?
        }
        struct DetailFragment: Decodable {
            var content: [String]?
            var exclude: [String]?
        }
        struct AttachmentsFragment: Decodable {
            var linkSelector: String?
            var extensions: [String]?
        }

        var list: ListFragment?
        var paging: PagingFragment?
        var detail: DetailFragment?
        var attachments: AttachmentsFragment?
    }

    private func callModel(plan: SitePlan, probe: SitePlanProbe, page: ParsedPage, html: String, feedback: String) async throws -> PlanFragment {
        guard let url = smart.chatCompletionsURL else {
            throw NetworkError.siteRefused("服务地址无效")
        }
        let outline = HTML.outline(html, maxChars: min(smart.maxInputChars, 12000))
        var lines: [String] = [
            "你是网页采集规则生成器。只输出 JSON，不要解释，也不要思考。",
            ##"输出格式：{"list":{"item":"CSS选择器","fields":{"title":{"selector":"a","attr":"text"},"url":{"selector":"a","attr":"href"},"date":{"selector":".date","attr":"text"}}},"paging":{"type":"link","selector":"a[title='下一页']","urlFrom":"onclick","template":"","param":{"base":"","name":"page","start":2,"end":20},"maxPages":20},"detail":{"content":["#content"],"exclude":[".share"]},"attachments":{"linkSelector":"a[href]","extensions":["pdf","doc","docx","xls","xlsx","jpg","png"]}}"##,
            "要求：",
            "1. list.item 是列表项整体的 CSS 选择器，不要使用 :nth-child，能被下一页复用；",
            "2. fields.url 取详情页地址，attr 可用 href/onclick/tagname；fields.title 取标题；fields.date 取日期，没有就留空；",
            "3. paging 只选一种：跟随下一页链接用 link；URL 页码模板用 template（含 {page}）；查询参数页码用 param；没有翻页用 none；",
            "4. detail.content 只选正文最小容器，最多 3 个，避开导航/面包屑/栏目菜单；detail.exclude 清掉评论、分享、相关推荐，最多 5 个；",
            "5. attachments.linkSelector 默认 a[href]；extensions 只保留真实附件类型；",
            "6. 找不到可靠规则时对应字段输出空串或空数组；不要输出解释。",
            "页面地址：\(page.finalURL.absoluteString)",
            "页面标题：\(page.title)"
        ]
        if !probe.item.isEmpty {
            lines.append("已探测候选：列表项=\(probe.item)（\(probe.count) 条）" +
                         (probe.paging.map { "；下一页元素=\($0.selector)" } ?? "") +
                         (probe.date.isEmpty ? "" : "；日期元素=\(probe.date)"))
        }
        if !feedback.isEmpty {
            lines.append("上次结果未通过校验：\(feedback)。请修正后重新输出完整 JSON。")
        }
        lines.append("DOM 骨架：")
        lines.append(outline)

        let payload: [String: Any] = [
            "model": smart.model,
            "temperature": 0,
            "max_tokens": 1000,
            "stream": false,
            "enable_thinking": false,
            "messages": [["role": "user", "content": lines.joined(separator: "\n")]]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let result = try await http.postJSON(url, body: body, extraHeaders: ["Authorization": "Bearer \(apiKey ?? "")"])
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
            throw NetworkError.siteRefused("响应中没有 JSON")
        }
        var candidate = String(text[start...])
        if let end = candidate.lastIndex(of: "}") {
            candidate = String(candidate[...end])
        }
        guard let data = candidate.data(using: .utf8),
              let fragment = try? JSONDecoder().decode(PlanFragment.self, from: data) else {
            throw NetworkError.siteRefused("响应格式非法：\(candidate.prefix(160))")
        }
        return fragment
    }

    private func merge(fragment: PlanFragment, into plan: inout SitePlan) {
        if let item = clean(fragment.list?.item) {
            plan.list.item = item
        }
        if let fields = fragment.list?.fields {
            if let title = fields.title {
                var value = title
                value.selector = clean(value.selector) ?? value.selector
                if !value.selector.isEmpty { plan.list.fields.title = value }
            }
            if let url = fields.url {
                var value = url
                value.selector = clean(value.selector) ?? value.selector
                if value.attr == .text { value.attr = .href }
                if !value.selector.isEmpty { plan.list.fields.url = value }
            }
            if let date = fields.date {
                var value = date
                value.selector = clean(value.selector) ?? ""
                plan.list.fields.date = value
            }
        }
        if let paging = fragment.paging {
            if let type = paging.type.flatMap({ SitePagingType(rawValue: $0) }) {
                plan.paging.type = type
            }
            if let selector = clean(paging.selector) { plan.paging.selector = selector }
            if let from = paging.urlFrom.flatMap({ SiteFieldAttr(rawValue: $0) }) { plan.paging.urlFrom = from }
            if let template = paging.template?.trimmed, !template.isEmpty { plan.paging.template = template }
            if let param = paging.param { plan.paging.param = param }
            if let maxPages = paging.maxPages { plan.paging.maxPages = min(max(1, maxPages), 100) }
        }
        if let detail = fragment.detail {
            let content = cleanList(detail.content ?? [], limit: 3)
            if !content.isEmpty { plan.detail.content = content }
            if let exclude = detail.exclude { plan.detail.exclude = cleanList(exclude, limit: 5) }
        }
        if let attachments = fragment.attachments {
            if let selector = clean(attachments.linkSelector) { plan.attachments.linkSelector = selector }
            if let extensions = attachments.extensions {
                let values = extensions.map { $0.trimmed.lowercased() }.filter { ConfigValidator.allowedTypes.contains($0) }
                if !values.isEmpty { plan.attachments.extensions = Array(Set(values)).sorted() }
            }
        }
    }

    // MARK: 工具

    private func score(_ validation: SitePlanValidation) -> Int {
        (validation.passed ? 1_000_000 : 0)
            + validation.listCount * 1000
            + validation.titleHits * 100
            + validation.urlHits * 10
            + min(validation.contentChars, 9999)
    }

    private func clean(_ value: String?) -> String? {
        guard let text = value?.trimmed, !text.isEmpty, text.count <= 160 else { return nil }
        guard !text.contains("<"), !text.contains("{"), !text.contains("}"), !text.contains(";") else { return nil }
        guard !text.lowercased().contains("javascript:") else { return nil }
        return text
    }

    private func cleanList(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard let cleaned = clean(value), seen.insert(cleaned).inserted else { continue }
            result.append(cleaned)
            if result.count >= limit { break }
        }
        return result
    }

    private static func cleanList(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let text = value.trimmed
            guard !text.isEmpty, text.count <= 160,
                  !text.contains("<"), !text.contains("{"), !text.contains("}"), !text.contains(";") else { continue }
            guard seen.insert(text).inserted else { continue }
            result.append(text)
            if result.count >= limit { break }
        }
        return result
    }
}

// MARK: - 脚本

enum SitePlanJS {
    static func probe() -> String {
        """
        (function(){
          function safeClass(c){ return /^[A-Za-z_][A-Za-z0-9_-]*$/.test(c) && !/\\d{5,}/.test(c); }
          function esc(s){ return String(s).replace(/([^a-zA-Z0-9_-])/g, '\\\\$1'); }
          function sel(el){
            if(!el || el.nodeType!==1) return '';
            var tag=el.tagName.toLowerCase();
            if(el.id && /^[A-Za-z_][A-Za-z0-9_-]*$/.test(el.id)) return tag+'#'+esc(el.id);
            var cls=[];
            if(typeof el.className==='string'){ cls=el.className.trim().split(/\\s+/).filter(safeClass).slice(0,2); }
            return tag+cls.map(function(c){return '.'+esc(c);}).join('');
          }
          function path(el){
            var parts=[], cur=el, guard=0;
            while(cur && cur.nodeType===1 && guard<4){
              var s=sel(cur);
              if(s) parts.unshift(s);
              if((cur.id && /^[A-Za-z_][A-Za-z0-9_-]*$/.test(cur.id)) || cur===document.body) break;
              cur=cur.parentElement; guard++;
            }
            return parts.join(' ');
          }
          function textOf(el){ return ((el.innerText!==undefined?el.innerText:el.textContent)||'').replace(/\\s+/g,' ').trim(); }
          function targetOf(a){
            var h=a.getAttribute('href')||'';
            if(h && h.toLowerCase().indexOf('javascript:')!==0) return h;
            var tg=a.getAttribute('tagname')||'';
            if(tg) return tg;
            var oc=a.getAttribute('data-onclick')||a.getAttribute('onclick')||'';
            var m=oc.match(/['"]([^'"]+\\.html?[^'"]*)['"]/i);
            return m?m[1]:h;
          }
          var containers=document.querySelectorAll('ul,ol,tbody,div,table,section,article');
          var best=null;
          for(var i=0;i<containers.length;i++){
            var el=containers[i];
            if(el===document.body) continue;
            var kids=[];
            for(var j=0;j<el.children.length;j++){
              var child=el.children[j];
              var a=child.querySelector ? child.querySelector('a') : null;
              if(!a) continue;
              var t=textOf(a);
              if(t.length<4) continue;
              kids.push({el:child,a:a,t:t});
            }
            if(kids.length<3) continue;
            var seen={},uniq=0,titleHits=0,sum=0;
            for(var k=0;k<kids.length;k++){
              var h=targetOf(kids[k].a);
              if(h && !seen[h]){ seen[h]=1; uniq++; }
              if(kids[k].t.length>=8) titleHits++;
              sum+=kids[k].t.length;
            }
            if(uniq<3) continue;
            var avg=sum/kids.length;
            var totalText=textOf(el).length;
            var score=kids.length*10+titleHits*2-Math.min(totalText/40,120);
            if(avg<8) score-=50;
            if(kids.length>200) score-=100;
            if(!best || score>best.score) best={el:el,kids:kids,score:score};
          }
          var result={count:0,item:'',title:'a',date:'',paging:null,samples:[]};
          if(best){
            var kids=best.kids;
            var tag=kids[0].el.tagName.toLowerCase();
            var same=true;
            for(var m=1;m<kids.length;m++){ if(kids[m].el.className!==kids[0].el.className){ same=false; break; } }
            var childSel=same?sel(kids[0].el):tag;
            if(!childSel) childSel=tag;
            var cp=path(best.el);
            result.item=(cp?cp+' ':'')+childSel;
            result.count=kids.length;
            var dateCounts={};
            for(var d=0;d<kids.length;d++){
              var nodes=kids[d].el.querySelectorAll('*');
              for(var n=0;n<nodes.length && n<40;n++){
                var tt=textOf(nodes[n]);
                if(tt.length>0 && tt.length<=20 && /\\d{4}[-\\/.年]\\d{1,2}[-\\/.月]\\d{1,2}/.test(tt)){
                  var ds=sel(nodes[n]);
                  if(ds) dateCounts[ds]=(dateCounts[ds]||0)+1;
                  break;
                }
              }
            }
            var dbest='',dc=0;
            for(var key in dateCounts){ if(dateCounts[key]>dc){ dc=dateCounts[key]; dbest=key; } }
            if(dc>=2) result.date=dbest;
            for(var s=0;s<kids.length && s<5;s++){
              result.samples.push({title:kids[s].t, url:targetOf(kids[s].a)});
            }
          }
          var words=['下一页','下页','后一页','next','›','»'];
          var anchors=document.querySelectorAll('a,button');
          for(var p=0;p<anchors.length;p++){
            var node=anchors[p];
            var label=(textOf(node)+' '+(node.getAttribute('title')||'')+' '+(node.getAttribute('aria-label')||'')).toLowerCase();
            var hit=false;
            for(var w=0;w<words.length;w++){ if(label.indexOf(words[w])>=0){ hit=true; break; } }
            if(!hit) continue;
            var href=node.getAttribute('href')||'';
            var click=node.getAttribute('data-onclick')||node.getAttribute('onclick')||'';
            var from='href', raw=href;
            if(!raw || raw.toLowerCase().indexOf('javascript:')===0){ raw=click; from='onclick'; }
            if(!raw) continue;
            var psel=path(node);
            var nodeTitle=node.getAttribute('title')||'';
            if(nodeTitle){ psel+='[title="'+nodeTitle.replace(/"/g,'\\\\"')+'"]'; }
            result.paging={selector:psel, urlFrom:from, label:textOf(node).slice(0,30)};
            break;
          }
          return JSON.stringify(result);
        })()
        """
    }

    /// 在详情页探测正文容器：按文本密度、段落数评分，排除导航/页脚/分享等噪声区域。
    static func contentProbe() -> String {
        """
        (function(){
          function safeClass(c){ return /^[A-Za-z_][A-Za-z0-9_-]*$/.test(c) && !/\\d{5,}/.test(c); }
          function esc(s){ return String(s).replace(/([^a-zA-Z0-9_-])/g, '\\\\$1'); }
          function sel(el){
            if(!el || el.nodeType!==1) return '';
            var tag=el.tagName.toLowerCase();
            if(el.id && /^[A-Za-z_][A-Za-z0-9_-]*$/.test(el.id)) return tag+'#'+esc(el.id);
            var cls=[];
            if(typeof el.className==='string'){ cls=el.className.trim().split(/\\s+/).filter(safeClass).slice(0,2); }
            return tag+cls.map(function(c){return '.'+esc(c);}).join('');
          }
          function path(el){
            var parts=[], cur=el, guard=0;
            while(cur && cur.nodeType===1 && guard<4){
              var s=sel(cur);
              if(s) parts.unshift(s);
              if((cur.id && /^[A-Za-z_][A-Za-z0-9_-]*$/.test(cur.id)) || cur===document.body) break;
              cur=cur.parentElement; guard++;
            }
            return parts.join(' ');
          }
          function textOf(el){ return ((el.innerText!==undefined?el.innerText:el.textContent)||'').replace(/\\s+/g,' ').trim(); }
          function noisy(el){
            var tag=el.tagName.toLowerCase();
            if(tag==='nav'||tag==='footer'||tag==='header'||tag==='aside') return true;
            var id=(el.id||'').toLowerCase();
            var cls=(typeof el.className==='string')?el.className.toLowerCase():'';
            var key=id+' '+cls;
            if(/(^|[\\s_-])(nav|menu|foot|footer|header|breadcrumb|crumb|sidebar|aside|copyright|share|comment|related|recommend|banner|toolbar|search|login|qrcode|friendlink|links?)([\\s_-]|$)/.test(key)) return true;
            if(el.getAttribute('role')==='navigation') return true;
            return false;
          }
          function insideNoisy(el){
            var cur=el;
            while(cur && cur.nodeType===1){ if(noisy(cur)) return true; cur=cur.parentElement; }
            return false;
          }
          var nodes=document.querySelectorAll('div,article,section,main,td');
          var cands=[],maxText=0;
          for(var c=0;c<nodes.length;c++){
            var el=nodes[c];
            if(el===document.body) continue;
            if(insideNoisy(el)) continue;
            var t=textOf(el);
            if(t.length<200) continue;
            var links=el.querySelectorAll('a');
            var linkText=0;
            for(var q=0;q<links.length;q++){ linkText+=textOf(links[q]).length; }
            var density=(t.length-linkText)/t.length;
            if(density<0.5) continue;
            if(t.length>maxText) maxText=t.length;
            cands.push({el:el, len:t.length, density:density, ps:el.querySelectorAll('p').length});
          }
          var best=null;
          for(var i=0;i<cands.length;i++){
            var it=cands[i];
            if(it.len<Math.max(200,maxText*0.3)) continue;
            var score=it.density*120+Math.min(it.ps,12)*3+Math.min(it.len,4000)/400;
            if(!best || score>best.score) best={el:it.el, score:score};
          }
          // 向内收紧到正文容器：逐层选择占父级文本 80% 以上的唯一子元素，剥离标题、工具条等小块。
          if(best){
            var cur=best.el;
            for(var d=0;d<8;d++){
              var total=textOf(cur).length;
              var pick=null;
              for(var j=0;j<cur.children.length;j++){
                var ch=cur.children[j];
                if(ch.tagName==='SCRIPT'||ch.tagName==='STYLE') continue;
                var cl=textOf(ch).length;
                if(total<=0 || cl<total*0.8) continue;
                if(!pick || cl>pick.len) pick={el:ch, len:cl};
              }
              if(!pick) break;
              var links2=pick.el.querySelectorAll('a'), lt=0;
              for(var q2=0;q2<links2.length;q2++){ lt+=textOf(links2[q2]).length; }
              var dens=pick.len>0?(pick.len-lt)/pick.len:0;
              if(dens<0.5) break;
              cur=pick.el;
            }
            best.el=cur;
          }
          var content=[];
          if(best){
            var s=sel(best.el), unique=false;
            try{ unique=document.querySelectorAll(s).length===1; }catch(e){}
            content.push(unique?s:path(best.el));
          }
          var exclude=[];
          var all=document.querySelectorAll('[class]');
          var badCounts={};
          for(var b=0;b<all.length;b++){
            var cn=(all[b].className&&typeof all[b].className==='string')?all[b].className:'';
            if(!cn) continue;
            if(!/comment|share|related|recommend|网友评论|相关阅读|相关推荐/.test(cn)) continue;
            var bs=sel(all[b]);
            if(!bs) continue;
            var lower=bs.toLowerCase();
            if(lower.indexOf('content')>=0 || lower.indexOf('article')>=0) continue;
            badCounts[bs]=(badCounts[bs]||0)+1;
          }
          var badKeys=Object.keys(badCounts);
          for(var k=0;k<badKeys.length && exclude.length<3;k++) exclude.push(badKeys[k]);
          return JSON.stringify({content:content, exclude:exclude});
        })()
        """
    }

    static func extractList(item: String, title: SiteField, url: SiteField, date: SiteField) -> String {
        """
        (function(){
          var items=[];
          try{ items=document.querySelectorAll(\(jsString(item))); }catch(e){ return JSON.stringify({error:'选择器语法错误', items:[]}); }
          function pick(scope, field){
            if(!field) return '';
            var el=scope;
            if(field.selector){ try{ el=scope.querySelector(field.selector); }catch(e){ el=null; } }
            if(!el) return '';
            var attr=(field.attr||'text').toLowerCase();
            var value='';
            if(attr==='text'){ value=(el.innerText!==undefined?el.innerText:el.textContent)||''; }
            else if(attr==='title'){ value=el.getAttribute('title')||''; }
            else if(attr==='datetime'){ value=el.getAttribute('datetime')||((el.innerText!==undefined?el.innerText:el.textContent)||''); }
            else { value=(attr==='onclick'?(el.getAttribute('data-onclick')||el.getAttribute('onclick')||''):el.getAttribute(attr))||''; }
            if((attr==='href'||attr==='src') && (!value || value.toLowerCase().indexOf('javascript:')===0)){
              value=el.getAttribute('tagname')||'';
              if(!value){
                var oc=el.getAttribute('data-onclick')||el.getAttribute('onclick')||'';
                var m=oc.match(/['"]([^'"]+\\.html?[^'"]*)['"]/i);
                if(m) value=m[1];
              }
            }
            if(attr==='onclick'){
              var m2=value.match(/['"]([^'"]+\\.html?[^'"]*)['"]/i);
              if(m2) value=m2[1];
            }
            return String(value).replace(/\\u00a0/g,' ').trim();
          }
          var out=[];
          for(var i=0;i<items.length;i++){
            out.push({
              title: pick(items[i], \(fieldJSON(title))),
              url: pick(items[i], \(fieldJSON(url))),
              date: pick(items[i], \(fieldJSON(date)))
            });
          }
          return JSON.stringify({items:out});
        })()
        """
    }

    static func nextPage(selector: String, urlFrom: String) -> String {
        """
        (function(){
          var nodes=[];
          try{ nodes=document.querySelectorAll(\(jsString(selector))); }catch(e){ return JSON.stringify({error:'选择器语法错误'}); }
          if(!nodes.length) return JSON.stringify({found:false});
          var from=\(jsString(urlFrom));
          for(var i=0;i<nodes.length;i++){
            var el=nodes[i];
            var label=(((el.innerText!==undefined?el.innerText:el.textContent)||'')+' '+(el.getAttribute('title')||'')+' '+(el.getAttribute('aria-label')||'')).toLowerCase();
            if(nodes.length>1 && !/下一页|下页|后一页|next|›|»/.test(label)) continue;
            var raw='';
            if(from==='href'){ raw=el.getAttribute('href')||''; }
            else if(from==='src'){ raw=el.getAttribute('src')||''; }
            else if(from==='tagname'){ raw=el.getAttribute('tagname')||''; }
            else {
              var oc=el.getAttribute('data-onclick')||el.getAttribute('onclick')||'';
              var m=oc.match(/['"]([^'"]+\\.html?[^'"]*)['"]/i);
              raw=m?m[1]:(from==='onclick'?oc:((el.innerText!==undefined?el.innerText:el.textContent)||''));
            }
            if(raw && raw.toLowerCase().indexOf('javascript:')===0){ raw=''; }
            if(!raw || /^\\[[A-Z]+\\]$/.test(raw.trim())) continue;
            return JSON.stringify({found:true, raw:raw, text:(el.innerText||'').slice(0,40)});
          }
          return JSON.stringify({found:false});
        })()
        """
    }

    static func attachmentURLs(selector: String) -> String {
        """
        (function(){
          var nodes=[];
          try{ nodes=document.querySelectorAll(\(jsString(selector)) || 'a[href]'); }catch(e){ return JSON.stringify({error:'选择器语法错误', urls:[]}); }
          var out=[];
          for(var i=0;i<nodes.length;i++){
            var el=nodes[i];
            var raw=el.getAttribute('href')||el.getAttribute('src')||el.getAttribute('tagname')||'';
            if(!raw || raw.toLowerCase().indexOf('javascript:')===0){
              var oc=el.getAttribute('data-onclick')||el.getAttribute('onclick')||'';
              var m=oc.match(/['"]([^'"]+\\.(?:pdf|docx?|xlsx?|jpe?g|png|zip|rar|7z)[^'"]*)['"]/i);
              if(m) raw=m[1];
            }
            if(!raw) continue;
            var abs=raw;
            try{ abs=new URL(raw, document.baseURI).href; }catch(e){}
            out.push(abs);
          }
          return JSON.stringify({urls:out});
        })()
        """
    }

    private static func fieldJSON(_ field: SiteField) -> String {
        let dict: [String: Any] = ["selector": field.selector, "attr": field.attr.rawValue]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }
}

// MARK: - 离线浏览器

@MainActor
final class SitePlanBrowser: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<String?, Never>?
    private var webView: WKWebView?
    private var finished = false
    private var script = ""
    private var timeout: Double = 12

    nonisolated static func evaluate(html: String, baseURL: URL?, script: String, timeout: Double = 12) async -> String? {
        let browser = await MainActor.run { SitePlanBrowser() }
        return await browser.run(html: preserveHandlers(html), baseURL: baseURL, script: script, timeout: timeout)
    }

    /// WKWebView 在关闭页面脚本后会移除 onclick 属性；先转存为 data-onclick，供规则读取。
    nonisolated static func preserveHandlers(_ html: String) -> String {
        var text = html
        let patterns = [
            (#"onclick\s*=\s*"([^"]*)""#, "data-onclick=\"$1\""),
            (#"onclick\s*=\s*'([^']*)'"#, "data-onclick=\"$1\"")
        ]
        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
        return text
    }

    private func run(html: String, baseURL: URL?, script: String, timeout: Double) async -> String? {
        finished = false
        self.script = script
        self.timeout = timeout
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        view.navigationDelegate = self
        webView = view

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            view.loadHTMLString(html, baseURL: baseURL)
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
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            Task { @MainActor in
                guard let self = self, !self.finished else { return }
                self.finish(value as? String)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }
}
