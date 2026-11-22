import Foundation
import AppKit

struct RunProgress {
    var status: String = "就绪"
    var category: String = ""
    var pageIndex: Int = 0
    var pageTotal: Int = 0
    var discoveredPages: Int = 0
    var visitedPages: Int = 0
    var attachmentsProcessed: Int = 0
    var elapsed: TimeInterval = 0
}

struct RunOutcome {
    let exitCode: Int32
    let summary: String
}

final class StopToken {
    private let lock = NSLock()
    private var value = false

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func stop() {
        lock.lock(); value = true; lock.unlock()
    }
}

struct CategoryStats {
    var pagesVisited = 0
    var pagesSkipped = 0
    var pagesFailed = 0
    var attachmentsFound = 0
    var attachmentsSkipped = 0
    var attachmentsSuccess = 0
    var attachmentsFailed = 0
    var pageTextsFound = 0
    var pageTextsSkipped = 0
    var pageTextsSuccess = 0
    var pageTextsFailed = 0
}

final class CategoryRuntime {
    let config: CategoryConfig
    let params: EffectiveParameters
    var pages: [ParsedPage] = []
    var pageKeys = Set<String>()
    var entryKeys = Set<String>()
    var paginationKeys = Set<String>()
    var planListKeys = Set<String>()
    var planDetails: [String: SiteDetailPlan] = [:]
    var planAttachments: [String: [RawAttachment]] = [:]
    var stats = CategoryStats()
    var discoveredCount = 0

    init(config: CategoryConfig, global: AppConfig) {
        self.config = config
        self.params = EffectiveParameters(global: global, category: config)
    }

    func contentTargets() -> [ParsedPage] {
        var seen = Set<String>()
        var targets: [ParsedPage] = []
        for page in pages where !entryKeys.contains(page.normalized) && !paginationKeys.contains(page.normalized) {
            if seen.insert(page.normalized).inserted { targets.append(page) }
        }
        if targets.isEmpty {
            for page in pages where entryKeys.contains(page.normalized) {
                if seen.insert(page.normalized).inserted { targets.append(page) }
            }
        }
        return targets
    }
}

private struct AttachmentJob {
    let page: ParsedPage
    let attachment: RawAttachment
    let candidates: [CategoryConfig]
    let ambiguous: Bool
    let hint: String
    let key: String
    var resolved: CategoryConfig?
    var usingDefault = false
}

private struct DownloadedFile {
    let fileURL: URL
    let fileName: String
    let size: Int64
    let md5: String
}

final class CollectionEngine {
    private let config: AppConfig
    private let log: LogStore
    private let forceFull: Bool
    private let stop: StopToken
    private let llmKey: String?
    private var onProgress: ((RunProgress) -> Void)?
    private let startDate = Date()

    private let limiter = RequestLimiter()
    private lazy var loader = PageLoader(config: config, log: log, limiter: limiter)
    private let sitePlanStore = SitePlanStore()
    private let recognizer = Recognizer()
    private var incremental: IncrementalStore?
    private var dbOutputs: [String: DatabaseOutput] = [:]
    private var feishuClients: [FeishuTarget: FeishuClient] = [:]
    private var feishuFailures: [FeishuTarget: String] = [:]
    private var smartJudge: SmartJudge?
    private var contentLocator: ContentLocator?
    private var totalVisits = 0
    private var globalLimitLogged = false
    private var currentPageIndex = 0
    private var totalPages = 0
    private var attachmentsProcessed = 0
    private var activityToken: NSObjectProtocol?
    private var defaultsStats = CategoryStats()
    private var maxLimitLogged = Set<String>()
    private var openStdRefusalLogged = false
    private var processedPerCategory: [String: Int] = [:]
    private let stagingDir: URL

    init(config: AppConfig, log: LogStore, forceFull: Bool, stop: StopToken, llmKey: String?, onProgress: ((RunProgress) -> Void)? = nil) {
        self.config = config
        self.log = log
        self.forceFull = forceFull
        self.stop = stop
        self.llmKey = llmKey
        self.onProgress = onProgress
        self.stagingDir = URL(fileURLWithPath: AppPaths.expand(config.stagingDir), isDirectory: true)
    }

    func run() async -> RunOutcome {
        AppPaths.ensureDirectories()
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "网页附件采集识别任务运行中"
        )
        defer {
            if let token = activityToken { ProcessInfo.processInfo.endActivity(token) }
            loader.shutdown()
            smartJudge?.close()
            contentLocator?.close()
            for (_, db) in dbOutputs { db.close() }
            incremental?.close()
        }

        log.info("仅采集已获授权的页面资源")
        emit("采集中")

        if config.categories.isEmpty && config.targetURL.trimmed.isEmpty {
            log.failed("请先填写采集目标地址")
            return RunOutcome(exitCode: 2, summary: "配置错误：请先填写采集目标地址")
        }

        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            log.failed("附件暂存目录无写入权限，请更换目录")
            return RunOutcome(exitCode: 2, summary: "配置错误：附件暂存目录不可用")
        }
        guard FileUtil.isWritableDirectory(stagingDir) else {
            log.failed("附件暂存目录无写入权限，请更换目录")
            return RunOutcome(exitCode: 2, summary: "配置错误：附件暂存目录不可写")
        }

        let store = IncrementalStore(path: AppPaths.expand(config.incrementalPath))
        incremental = store
        if !store.available {
            log.failed("增量记录文件无法读取，已按全量模式处理本次采集")
        }

        var runtimes: [CategoryRuntime] = []
        var simplePage: ParsedPage?

        if config.categories.filter({ $0.enabled }).isEmpty {
            // R-M5-18 单页面模式
            guard let url = URL(string: config.targetURL.trimmed) else {
                log.failed("请先填写采集目标地址")
                return RunOutcome(exitCode: 2, summary: "配置错误：采集目标地址无效")
            }
            do {
                let page = try await loader.load(url, useDynamic: config.dynamicRendering)
                simplePage = page
                defaultsStats.pagesVisited += 1
                totalVisits += 1
                totalPages = 1
                log.info("页面解析完成：\(page.title)")
            } catch {
                let message = pageErrorMessage(error, url: url)
                log.failed(message)
                defaultsStats.pagesFailed += 1
                return RunOutcome(exitCode: 1, summary: "采集失败：\(message)")
            }
        } else {
            for category in config.categories where category.enabled {
                let runtime = CategoryRuntime(config: category, global: config)
                runtimes.append(runtime)
            }
            for runtime in runtimes {
                if stop.isStopped { break }
                log.info("分类开始：\(runtime.config.name)")
                await buildPages(runtime: runtime)
            }
            totalPages = runtimes.reduce(0) { $0 + $1.pages.count }
        }

        if stop.isStopped {
            let summary = buildSummary(runtimes: runtimes)
            log.info("采集已停止，已完成的数据已保留")
            log.summary(summary)
            emit("已停止")
            return RunOutcome(exitCode: failureCount(runtimes: runtimes) > 0 ? 1 : 0, summary: summary)
        }

        if config.smart.enabled, let key = llmKey, !key.isEmpty {
            smartJudge = SmartJudge(config: config.smart, apiKey: key, allCategories: config.categories, log: log)
        }
        if config.smart.locateContent, let key = llmKey, !key.isEmpty {
            contentLocator = ContentLocator(config: config.smart, apiKey: key, log: log)
        }

        if !runtimes.isEmpty {
            await processPageTexts(runtimes: runtimes)
        }
        if stop.isStopped {
            let summary = buildSummary(runtimes: runtimes)
            log.info("采集已停止，已完成的数据已保留")
            log.summary(summary)
            emit("已停止")
            return RunOutcome(exitCode: failureCount(runtimes: runtimes) > 0 ? 1 : 0, summary: summary)
        }

        let jobs = buildJobs(runtimes: runtimes, simplePage: simplePage)
        var resolvedJobs = jobs
        await resolveAmbiguity(jobs: &resolvedJobs)
        await processJobs(resolvedJobs, runtimes: runtimes, simplePage: simplePage)

        let summary = buildSummary(runtimes: runtimes)
        log.summary(summary)
        if config.smart.enabled, let judge = smartJudge {
            log.summary("智能判定：调用 \(judge.metrics.calls) 次 / 缓存命中 \(judge.metrics.cacheHits) 次 / 回退 \(judge.metrics.fallbacks) 次 / 预算耗尽：\(judge.metrics.budgetExhausted ? "是" : "否")")
        }
        let failed = failureCount(runtimes: runtimes)
        let status = stop.isStopped ? "已停止" : (failed > 0 ? "出错" : "已完成")
        emit(status)
        return RunOutcome(exitCode: failed > 0 ? 1 : 0, summary: summary)
    }

    // MARK: - 页面发现

    private func buildPages(runtime: CategoryRuntime) async {
        let rawURLs = runtime.config.pageURLs
        var entryPages: [ParsedPage] = []
        var seenEntry = Set<String>()
        var duplicates = false
        for text in rawURLs {
            guard let url = URL(string: text) else {
                runtime.stats.pagesFailed += 1
                log.failed("页面发现失败：\(text)，已跳过", category: runtime.config.name)
                continue
            }
            let norm = Address.normalize(url.absoluteString)
            if seenEntry.contains(norm) { duplicates = true; continue }
            seenEntry.insert(norm)
            if stop.isStopped { break }
            do {
                let planned = sitePlanStore.plan(for: url) != nil
                let page = try await loadVisited(url: url, runtime: runtime, keepHTML: planned ? true : nil)
                entryPages.append(page)
                runtime.entryKeys.insert(page.normalized)
                addPage(page, to: runtime)
            } catch {
                runtime.stats.pagesFailed += 1
                log.failed(pageErrorMessage(error, url: url), category: runtime.config.name)
            }
        }
        if duplicates {
            log.info("分类「\(runtime.config.name)」存在重复地址，已合并", category: runtime.config.name)
        }

        // 有已确认方案时，按方案发现列表与详情页；该入口不再走默认翻页/遍历。
        var plannedEntries = Set<String>()
        for entry in entryPages {
            guard let plan = sitePlanStore.plan(for: entry.finalURL) else { continue }
            plannedEntries.insert(entry.normalized)
            await discoverByPlan(plan: plan, entry: entry, runtime: runtime)
        }

        let discovery = runtime.config.discovery
        guard discovery.mode != .entry, !entryPages.isEmpty else { return }
        let defaultEntries = entryPages.filter { !plannedEntries.contains($0.normalized) }
        if defaultEntries.isEmpty { return }

        var paginationPages: [ParsedPage] = []
        if discovery.hasPagination {
            for entry in defaultEntries {
                if stop.isStopped { break }
                if discovery.pagingMode == .nextLink {
                    paginationPages.append(contentsOf: await paginateByNextLink(runtime: runtime, entry: entry))
                } else {
                    paginationPages.append(contentsOf: await paginateByTemplate(runtime: runtime, entry: entry))
                }
            }
        }

        if discovery.hasCrawl {
            let starts = discovery.mode == .both ? defaultEntries + paginationPages : defaultEntries
            for start in starts {
                if stop.isStopped { break }
                await crawl(runtime: runtime, from: start)
            }
            if !discovery.pageKeywords.trimmed.isEmpty && runtime.pages.count <= entryPages.count {
                log.info("页面发现完成，无符合关键词的页面", category: runtime.config.name)
            }
        }
    }

    /// 按站点方案执行：列表页解析字段，按方案翻页，详情页沿用现有正文与附件链路。
    private func discoverByPlan(plan: SitePlan, entry: ParsedPage, runtime: CategoryRuntime) async {
        let category = runtime.config.name
        let discovery = runtime.config.discovery
        log.info("采集方案：命中模板缓存（\(plan.version)）", category: category)
        runtime.planListKeys.insert(entry.normalized)
        runtime.planDetails[entry.normalized] = plan.detail

        var current = entry
        var seenPages = Set([entry.normalized])
        var pageNumber = 1
        let maxPages = min(max(1, plan.paging.maxPages), max(1, discovery.maxPages))

        while !stop.isStopped {
            if palgeLimitReached(runtime) {
                log.info("页面发现已达上限 \(discovery.maxPages) 个，已停止继续发现", category: category)
                break
            }
            guard let html = current.sourceHTML else {
                log.smart("采集方案：列表页未保留源码，已回退默认规则")
                return
            }
            let base = SitePlanExtractor.baseURL(html: html, pageURL: current.finalURL)
            let items = await SitePlanExtractor.listItems(html: html, base: base, plan: plan)
            var added = 0
            for item in items {
                if stop.isStopped || palgeLimitReached(runtime) { break }
                guard !item.url.trimmed.isEmpty, let url = URL(string: item.url) else { continue }
                if Address.allowedExtension(url) != nil { continue }
                let norm = Address.normalize(url.absoluteString)
                if norm == entry.normalized || runtime.pageKeys.contains(norm) { continue }
                if isExcluded(norm, rules: discovery.mustExclude) {
                    runtime.stats.pagesSkipped += 1
                    continue
                }
                do {
                    let page = try await loadVisited(url: url, runtime: runtime, keepHTML: true)
                    guard evaluate(page: page, runtime: runtime, source: current.finalURL.absoluteString, depth: 0) else { continue }
                    runtime.discoveredCount += 1
                    runtime.planDetails[page.normalized] = plan.detail
                    await registerPlanAttachments(plan: plan, page: page, runtime: runtime)
                    addPage(page, to: runtime)
                    added += 1
                } catch {
                    runtime.stats.pagesFailed += 1
                    log.failed(pageErrorMessage(error, url: url), category: category)
                }
            }
            log.info("采集方案：列表页解析 \(items.count) 条，新增 \(added) 条", category: category)

            if plan.paging.type == .none { break }
            if pageNumber >= maxPages {
                log.info("采集方案：已达翻页上限 \(maxPages) 页，已停止", category: category)
                break
            }
            let nextURL: URL?
            switch plan.paging.type {
            case .link:
                nextURL = (await SitePlanExtractor.nextPageURL(html: html, base: base, paging: plan.paging))?.url
                if nextURL == nil {
                    log.info("采集方案：未找到下一页元素，已停止翻页", category: category)
                }
            case .template:
                nextURL = SitePlanExtractor.templateURL(paging: plan.paging, pageNumber: pageNumber + 1, base: base)
            case .param:
                nextURL = SitePlanExtractor.paramURL(paging: plan.paging, pageNumber: pageNumber + 1, base: base)
            case .none:
                nextURL = nil
            }
            guard let next = nextURL else { break }
            let norm = Address.normalize(next.absoluteString)
            if seenPages.contains(norm) {
                log.info("采集方案：翻页地址重复，已停止翻页", category: category)
                break
            }
            if isExcluded(norm, rules: discovery.mustExclude) {
                runtime.stats.pagesSkipped += 1
                break
            }
            seenPages.insert(norm)
            do {
                current = try await loadVisited(url: next, runtime: runtime, keepHTML: true)
            } catch {
                if let network = error as? NetworkError, case .badStatus(let code, _) = network, code == 404 || code == 410 {
                    log.info("采集方案：第 \(pageNumber + 1) 页返回 \(code)，已停止", category: category)
                } else {
                    runtime.stats.pagesFailed += 1
                    log.failed("采集方案：翻页失败 \(next.absoluteString)，已停止", category: category)
                }
                break
            }
            pageNumber += 1
            runtime.planListKeys.insert(current.normalized)
            let stopWhen = plan.paging.stopWhen.trimmed
            if !stopWhen.isEmpty && current.contentText.contains(stopWhen) {
                log.info("采集方案：命中停止条件「\(stopWhen)」，已停止翻页", category: category)
                break
            }
        }
    }

    /// 方案附件规则：自定义链接选择器时先按 DOM 提取，再按扩展名过滤；否则复用全页扫描结果。
    private func registerPlanAttachments(plan: SitePlan, page: ParsedPage, runtime: CategoryRuntime) async {
        let selector = plan.attachments.linkSelector.trimmed
        if !selector.isEmpty, selector != "a[href]", let html = page.sourceHTML {
            let base = SitePlanExtractor.baseURL(html: html, pageURL: page.finalURL)
            let urls = await SitePlanExtractor.attachmentURLs(html: html, base: base, selector: selector)
            let values = SitePlanExtractor.filterAttachments(
                urls.map { RawAttachment(url: $0, nameHint: nil, openStdHcno: nil) },
                plan: plan
            )
            if !values.isEmpty {
                runtime.planAttachments[page.normalized] = values
                return
            }
        }
        runtime.planAttachments[page.normalized] = SitePlanExtractor.filterAttachments(page.attachments, plan: plan)
    }

    @discardableResult
    private func loadVisited(url: URL, runtime: CategoryRuntime, keepHTML: Bool? = nil) async throws -> ParsedPage {
        totalVisits += 1
        if totalVisits > 2000 {
            if !globalLimitLogged {
                globalLimitLogged = true
                log.failed("单次任务访问页面已达上限 2000 个，已停止页面发现")
            }
        }
        runtime.stats.pagesVisited += 1
        emit("采集中", category: runtime.config.name)
        return try await loader.load(url, useDynamic: runtime.params.dynamicRendering, keepHTML: keepHTML)
    }

    private func addPage(_ page: ParsedPage, to runtime: CategoryRuntime) {
        if runtime.pageKeys.insert(page.normalized).inserted {
            runtime.pages.append(page)
        }
    }

    private func palgeLimitReached(_ runtime: CategoryRuntime) -> Bool {
        if runtime.discoveredCount >= runtime.config.discovery.maxPages {
            return true
        }
        return totalVisits > 2000
    }

    private func paginateByNextLink(runtime: CategoryRuntime, entry: ParsedPage) async -> [ParsedPage] {
        var result: [ParsedPage] = []
        var current = entry
        var seen = Set([entry.normalized])
        let discovery = runtime.config.discovery
        let words = discovery.nextLinkWords.components(separatedBy: ",").map { $0.trimmed.lowercased() }.filter { !$0.isEmpty }
        let fallbackWords = ["下一页", "下页", "后一页", "next", "›", "»"]

        while !stop.isStopped {
            if palgeLimitReached(runtime) {
                log.info("页面发现已达上限 \(discovery.maxPages) 个，已停止继续发现", category: runtime.config.name)
                break
            }
            let match = current.anchors.first { anchor in
                let text = (anchor.text + " " + anchor.ariaLabel + " " + anchor.title).lowercased()
                return (words.isEmpty ? fallbackWords : words).contains { text.contains($0) }
            }
            guard let next = match?.url else {
                log.info("未识别到下一页链接，已停止翻页", category: runtime.config.name)
                break
            }
            let norm = Address.normalize(next.absoluteString)
            if isExcluded(norm, rules: discovery.mustExclude) {
                runtime.stats.pagesSkipped += 1
                log.skipped("\(next.absoluteString)：页面地址命中排除规则，已跳过", category: runtime.config.name)
                break
            }
            if seen.contains(norm) {
                log.info("翻页地址重复，已停止翻页", category: runtime.config.name)
                break
            }
            seen.insert(norm)
            if totalVisits > 2000 {
                if !globalLimitLogged {
                    globalLimitLogged = true
                    log.info("单次任务访问页面已达上限 2000 个，已停止页面发现", category: runtime.config.name)
                }
                break
            }
            do {
                let page = try await loadVisited(url: next, runtime: runtime)
                runtime.discoveredCount += 1
                seen.insert(page.normalized)
                let accepted = evaluate(page: page, runtime: runtime, source: current.finalURL.absoluteString, depth: 0)
                if accepted {
                    runtime.paginationKeys.insert(page.normalized)
                    addPage(page, to: runtime)
                }
                result.append(page)
                current = page
            } catch {
                runtime.stats.pagesFailed += 1
                log.failed("页面发现失败：\(next.absoluteString)，已跳过", category: runtime.config.name)
                break
            }
        }
        return result
    }

    private func paginateByTemplate(runtime: CategoryRuntime, entry: ParsedPage) async -> [ParsedPage] {
        var result: [ParsedPage] = []
        let discovery = runtime.config.discovery
        let template = discovery.pageTemplate
        var previous: ParsedPage?
        var reachedMax = true

        for pageNumber in discovery.startPage...discovery.maxPage {
            if stop.isStopped { return result }
            if palgeLimitReached(runtime) {
                log.info("页面发现已达上限 \(discovery.maxPages) 个，已停止继续发现", category: runtime.config.name)
                reachedMax = false
                break
            }
            let text = template.replacingOccurrences(of: "{页码}", with: "\(pageNumber)")
            guard let url = URL(string: text) else { break }
            let norm = Address.normalize(url.absoluteString)
            if norm == entry.normalized { continue }
            if isExcluded(norm, rules: discovery.mustExclude) {
                runtime.stats.pagesSkipped += 1
                log.skipped("\(text)：页面地址命中排除规则，已跳过", category: runtime.config.name)
                break
            }
            do {
                let page = try await loadVisited(url: url, runtime: runtime)
                if page.title == "未命名页面" && page.links.isEmpty && page.attachments.isEmpty {
                    log.info("URL 页码翻页未获取到有效页面，已停止", category: runtime.config.name)
                    break
                }
                if let prev = previous, prev.title == page.title && prev.text == page.text {
                    log.info("URL 页码翻页内容重复，已停止", category: runtime.config.name)
                    break
                }
                runtime.discoveredCount += 1
                let accepted = evaluate(page: page, runtime: runtime, source: entry.finalURL.absoluteString, depth: 0)
                if accepted {
                    runtime.paginationKeys.insert(page.normalized)
                    addPage(page, to: runtime)
                }
                result.append(page)
                previous = page
            } catch {
                if let network = error as? NetworkError, case .badStatus(let code, _) = network, code == 404 || code == 410 {
                    log.info("URL 页码翻页在第 \(pageNumber) 页返回 \(code)，已停止", category: runtime.config.name)
                } else {
                    runtime.stats.pagesFailed += 1
                    log.failed("页面发现失败：\(text)，已跳过", category: runtime.config.name)
                }
                reachedMax = false
                break
            }
        }
        if reachedMax && !stop.isStopped {
            log.info("已达到最大页码 \(discovery.maxPage)，已停止翻页", category: runtime.config.name)
        }
        return result
    }

    private func crawl(runtime: CategoryRuntime, from start: ParsedPage) async {
        let discovery = runtime.config.discovery
        var queue: [(url: URL, source: String, depth: Int)] = []
        var seen = Set<String>()
        seen.insert(start.normalized)
        for page in runtime.pages { seen.insert(page.normalized) }

        func enqueue(_ page: ParsedPage, depth: Int) {
            guard depth <= discovery.maxDepth else { return }
            for link in page.links {
                if Address.isIgnorableLink(link) { continue }
                if Address.allowedExtension(link) != nil { continue }
                guard Address.sameDomain(link.absoluteString, page.finalURL.absoluteString) else { continue }
                let norm = Address.normalize(link.absoluteString)
                if seen.contains(norm) { continue }
                seen.insert(norm)
                queue.append((link, page.finalURL.absoluteString, depth))
            }
        }

        enqueue(start, depth: 1)

        while !queue.isEmpty && !stop.isStopped {
            if palgeLimitReached(runtime) {
                log.info("页面发现已达上限 \(discovery.maxPages) 个，已停止继续发现", category: runtime.config.name)
                break
            }
            if totalVisits > 2000 {
                if !globalLimitLogged {
                    globalLimitLogged = true
                    log.info("单次任务访问页面已达上限 2000 个，已停止页面发现", category: runtime.config.name)
                }
                break
            }
            let item = queue.removeFirst()
            let norm = Address.normalize(item.url.absoluteString)
            if isExcluded(norm, rules: discovery.mustExclude) {
                runtime.stats.pagesSkipped += 1
                log.skipped("\(item.url.absoluteString)：页面地址命中排除规则，已跳过", category: runtime.config.name)
                continue
            }
            do {
                let page = try await loadVisited(url: item.url, runtime: runtime)
                runtime.discoveredCount += 1
                seen.insert(page.normalized)
                let accepted = evaluate(page: page, runtime: runtime, source: item.source, depth: item.depth)
                if accepted { addPage(page, to: runtime) }
                if item.depth < discovery.maxDepth {
                    enqueue(page, depth: item.depth + 1)
                }
            } catch {
                if let network = error as? NetworkError, case .notAllowedType = network {
                    runtime.stats.pagesSkipped += 1
                    log.skipped("\(item.url.absoluteString)（原因：非 HTML 响应）", category: runtime.config.name)
                } else {
                    runtime.stats.pagesFailed += 1
                    log.failed("页面发现失败：\(item.url.absoluteString)，已跳过", category: runtime.config.name)
                }
            }
        }
    }

    /// 返回该发现页面是否加入页面集合（采集附件）。
    private func evaluate(page: ParsedPage, runtime: CategoryRuntime, source: String, depth: Int) -> Bool {
        let discovery = runtime.config.discovery
        let keywordHit = keywordMatches(page: page, discovery: discovery)
        let includeOK = includeMatches(page.normalized, rules: discovery.mustInclude)
        if !includeOK {
            log.info("页面未命中地址包含规则，仅继续遍历", category: runtime.config.name)
        }
        let collect = keywordHit && includeOK
        log.discovered("\(page.finalURL.absoluteString)（来源：\(source)，深度：\(depth)，关键词：\(keywordHit ? "命中" : "未命中")，采集：\(collect ? "是" : "否")", category: runtime.config.name)
        return collect
    }

    private func keywordMatches(page: ParsedPage, discovery: DiscoveryConfig) -> Bool {
        let keywords = discovery.pageKeywords.components(separatedBy: ",").map { $0.trimmed.lowercased() }.filter { !$0.isEmpty }
        if keywords.isEmpty { return true }
        var haystacks: [String] = []
        if discovery.scope.title { haystacks.append(page.title.lowercased()) }
        if discovery.scope.url { haystacks.append(page.normalized.lowercased()) }
        if discovery.scope.body { haystacks.append(page.text.lowercased()) }
        return keywords.contains { keyword in haystacks.contains { $0.contains(keyword) } }
    }

    private func includeMatches(_ normalizedURL: String, rules: String) -> Bool {
        let values = rules.components(separatedBy: ",").map { $0.trimmed.lowercased() }.filter { !$0.isEmpty }
        if values.isEmpty { return true }
        let lower = normalizedURL.lowercased()
        return values.contains { lower.contains($0) }
    }

    private func isExcluded(_ normalizedURL: String, rules: String) -> Bool {
        let values = rules.components(separatedBy: ",").map { $0.trimmed.lowercased() }.filter { !$0.isEmpty }
        guard !values.isEmpty else { return false }
        let lower = normalizedURL.lowercased()
        return values.contains { lower.contains($0) }
    }

    // MARK: - 页面正文

    /// 站点方案优先；其次模板缓存；默认规则质量不佳时请模型定位；失败均回退默认规则。
    private func resolvedContentText(for page: ParsedPage, category: String, runtime: CategoryRuntime) async -> String {
        if let detail = runtime.planDetails[page.normalized], !detail.content.isEmpty, let html = page.sourceHTML {
            let extractor = await MainActor.run { SelectorTextExtractor.shared() }
            if let text = await extractor.extract(html: html, content: detail.content, exclude: detail.exclude), text.count >= 30 {
                log.info("采集方案：按方案正文提取（\(detail.content.joined(separator: ", "))）", category: category)
                return text
            }
            log.smart("采集方案：正文选择器未取到有效正文，已回退默认规则")
        }
        guard let locator = contentLocator, let html = page.sourceHTML else {
            return page.contentText.trimmed
        }
        if let plan = locator.cachedPlan(for: page.finalURL) {
            if let text = await locator.extract(html: html, plan: plan), text.count >= 30 {
                if isLocatorResultWorse(text, than: page.contentText) {
                    log.smart("正文定位：缓存选择器结果明显偏少（\(text.count) 字，默认 \(page.contentText.count) 字），已回退默认规则")
                    return page.contentText.trimmed
                }
                log.info("正文定位：命中模板缓存（\(plan.content.joined(separator: ", "))）", category: category)
                return text
            }
            log.smart("正文定位：缓存选择器未取到有效正文，已回退默认规则")
            return page.contentText.trimmed
        }

        let quality = HTML.contentQuality(page.contentText)
        guard quality.poor else { return page.contentText.trimmed }
        if let plan = await locator.learn(for: page, html: html, reason: quality.reason) {
            if let text = await locator.extract(html: html, plan: plan), text.count >= 30 {
                if isLocatorResultWorse(text, than: page.contentText) {
                    log.smart("正文定位：模型选择器结果偏少或不佳（\(text.count) 字，默认 \(page.contentText.count) 字），已回退默认规则")
                } else {
                    log.info("正文定位：已按模型选择器提取（\(plan.content.joined(separator: ", "))）", category: category)
                    return text
                }
            } else {
                log.smart("正文定位：模型选择器未取到有效正文，已回退默认规则")
            }
        }
        return page.contentText.trimmed
    }

    /// 模型选择器可能误选导航：结果含多个导航词且明显短于默认提取时，视为失败。
    private func isLocatorResultWorse(_ text: String, than fallback: String) -> Bool {
        HTML.navigationWordCount(text) >= 3 && text.count < fallback.count / 2
    }

    private func processPageTexts(runtimes: [CategoryRuntime]) async {
        for runtime in runtimes {
            guard runtime.config.enabled, runtime.params.contentMode.includesText else { continue }
            let categoryName = runtime.config.name
            for page in runtime.contentTargets() {
                if stop.isStopped { break }
                runtime.stats.pageTextsFound += 1
                let title = page.title.trimmed.isEmpty ? page.normalized : page.title.trimmed
                let text = await resolvedContentText(for: page, category: categoryName, runtime: runtime)
                if text.count < 30 {
                    runtime.stats.pageTextsSkipped += 1
                    log.skipped("正文：\(title)：正文过短（\(text.count) 字），已跳过", category: categoryName)
                    continue
                }

                let md5 = FileUtil.md5(of: text)
                if !forceFull, let store = incremental, store.available {
                    let hit = store.lookup(category: categoryName, address: page.normalized)
                    if hit.found, hit.md5 == md5 {
                        runtime.stats.pageTextsSkipped += 1
                        log.skipped("正文：\(title)：正文未变化，已跳过", category: categoryName)
                        continue
                    }
                }

                log.added("正文：\(title)（\(text.count) 字）", category: categoryName)
                let record = CollectedRecord(
                    categoryName: categoryName,
                    pageTitle: title,
                    pageURL: page.finalURL.absoluteString,
                    attachmentURL: "",
                    fileName: "",
                    size: 0,
                    content: "",
                    md5: md5,
                    collectedAt: TimeFormat.string(),
                    recordType: .pageText,
                    pageText: text
                )
                let report = await writeOutputs(record: record, fileURL: nil, category: runtime.config, md5: md5)

                let successCount = report.successes.count
                let failCount = report.failures.count
                let status: String
                if failCount == 0 {
                    status = "成功"
                } else if successCount == 0 {
                    status = "失败"
                } else {
                    status = "部分失败"
                }
                let reason = report.failures.joined(separator: "；")
                if let (db, rowID) = report.databaseRow {
                    db.updateStatus(rowID: rowID, status: status, reason: reason)
                }

                if status == "成功" {
                    runtime.stats.pageTextsSuccess += 1
                    log.completed("正文：\(title)", category: categoryName)
                    if let store = incremental, store.available {
                        try? store.upsert(
                            category: categoryName,
                            address: page.normalized,
                            pageURL: page.finalURL.absoluteString,
                            md5: md5,
                            time: TimeFormat.string()
                        )
                    }
                } else {
                    runtime.stats.pageTextsFailed += 1
                    log.failed("正文：\(title)：\(reason.isEmpty ? "输出失败" : reason)", category: categoryName)
                }
            }
        }
        if stop.isStopped {
            log.info("采集已停止，已完成的数据已保留")
        }
    }

    // MARK: - 归属

    private func buildJobs(runtimes: [CategoryRuntime], simplePage: ParsedPage?) -> [AttachmentJob] {
        var jobs: [AttachmentJob] = []
        var seen = Set<String>()

        func appendJobs(page: ParsedPage, runtime: CategoryRuntime?) {
            if let runtime = runtime, runtime.planListKeys.contains(page.normalized) {
                log.info("采集方案：列表页仅用于发现，跳过其附件", category: runtime.config.name)
                return
            }
            let owning = runtimes.filter { $0.pageKeys.contains(page.normalized) && $0.config.enabled }
            let pageCandidates = owning.filter { $0.params.contentMode.includesAttachments }
            if !owning.isEmpty && pageCandidates.isEmpty {
                log.info("本页仅启用正文采集，跳过附件", category: owning[0].config.name)
                return
            }
            let attachments = runtime.flatMap { $0.planAttachments[page.normalized] } ?? page.attachments
            if attachments.isEmpty {
                log.info("本页未发现可采集附件", category: runtime?.config.name ?? "默认分类")
                return
            }
            for attachment in attachments {
                let attURL = attachment.url.absoluteString
                let dedupe = Address.normalize(attURL)
                if seen.contains(dedupe) { continue }
                seen.insert(dedupe)
                let hint = attachment.nameHint?.trimmed ?? URLComponents(url: attachment.url, resolvingAgainstBaseURL: false)?.path.split(separator: "/").last.map { String($0).removingPercentEncoding ?? String($0) } ?? page.title
                let candidates = pageCandidates.map { $0.config }
                let (ambiguous, filtered) = ruleCandidates(filename: hint, candidates: candidates)
                let job = AttachmentJob(
                    page: page,
                    attachment: attachment,
                    candidates: filtered,
                    ambiguous: ambiguous,
                    hint: hint.isEmpty ? page.title : hint,
                    key: page.normalized + "|" + dedupe,
                    resolved: nil,
                    usingDefault: false
                )
                jobs.append(job)
                _ = runtime
            }
        }

        if let page = simplePage {
            appendJobs(page: page, runtime: nil)
            return jobs
        }

        for runtime in runtimes {
            for page in runtime.pages {
                appendJobs(page: page, runtime: runtime)
            }
        }
        return jobs
    }

    /// R-M5-05 第 1–3 步：返回 (是否仍需第 4 步选择, 候选集合)。
    private func ruleCandidates(filename: String, candidates: [CategoryConfig]) -> (Bool, [CategoryConfig]) {
        if candidates.count <= 1 { return (false, candidates) }
        let lower = filename.lowercased()
        let hits = candidates.filter { category in
            let keywords = category.attachmentKeywordList
            return !keywords.isEmpty && keywords.contains { lower.contains($0) }
        }
        let filtered = hits.isEmpty ? candidates : hits
        return (filtered.count > 1, filtered)
    }

    private func resolveAmbiguity(jobs: inout [AttachmentJob]) async {
        guard !jobs.isEmpty else { return }
        let ambiguousJobs = jobs.filter { $0.ambiguous }
        var resolutions: [String: UUID] = [:]

        if !ambiguousJobs.isEmpty, config.smart.enabled, let judge = smartJudge {
            let items = ambiguousJobs.map { job in
                SmartItem(
                    key: job.key,
                    pageNormalized: job.page.normalized,
                    pageTitle: job.page.title,
                    fileName: job.hint,
                    candidates: job.candidates
                )
            }
            let judged = await judge.resolve(items: items)
            for (key, value) in judged {
                if let value = value { resolutions[key] = value }
            }
        }

        for index in jobs.indices {
            let job = jobs[index]
            if let chosenID = resolutions[job.key], let category = job.candidates.first(where: { $0.id == chosenID }) {
                jobs[index].resolved = category
                continue
            }
            if job.candidates.count > 1 {
                let chosen = job.candidates.first
                jobs[index].resolved = chosen
                log.info("命中多个分类，按顺序归入：\(chosen?.name ?? "默认分类")", category: chosen?.name)
            } else if let unique = job.candidates.first {
                jobs[index].resolved = unique
            } else {
                jobs[index].usingDefault = true
            }
        }
    }

    // MARK: - 附件处理

    private func processJobs(_ input: [AttachmentJob], runtimes: [CategoryRuntime], simplePage: ParsedPage?) async {
        guard !input.isEmpty else {
            let hasAttachmentCategory = simplePage != nil || runtimes.contains {
                $0.config.enabled && $0.params.contentMode.includesAttachments
            }
            if hasAttachmentCategory {
                log.info("本页未发现可采集附件")
            }
            return
        }

        var lastPageKey = ""
        var lastCategory = ""

        for job in input {
            if stop.isStopped { break }

            let category: CategoryConfig?
            if let resolved = job.resolved {
                category = resolved
            } else {
                category = nil
            }
            let categoryName = category?.name ?? "默认分类"
            let params = EffectiveParameters(global: config, category: category)

            if job.page.normalized != lastPageKey || categoryName != lastCategory {
                if job.page.normalized != lastPageKey { currentPageIndex += 1 }
                lastPageKey = job.page.normalized
                lastCategory = categoryName
                emit("采集中", category: categoryName)
            }

            let processed = processedPerCategory[categoryName] ?? 0
            if processed >= params.maxAttachments {
                if !maxLimitLogged.contains(categoryName) {
                    maxLimitLogged.insert(categoryName)
                    let message = "已达到最大采集附件数 \(params.maxAttachments)，停止处理分类「\(categoryName)」剩余附件"
                    log.info(message, category: categoryName)
                }
                bumpStats(categoryName, runtimes: runtimes, simple: simplePage, found: true, skipped: true)
                continue
            }

            // 增量判定
            let attachmentURL = job.attachment.url.absoluteString
            var previousMD5: String?
            if config.incrementalEnabled && !forceFull, let store = incremental, store.available {
                let result = store.lookup(category: categoryName, address: attachmentURL)
                if result.found {
                    if params.incrementalRule == .address {
                        log.skipped("\(job.hint)（增量命中）", category: categoryName)
                        bumpStats(categoryName, runtimes: runtimes, simple: simplePage, found: true, skipped: true)
                        continue
                    }
                    previousMD5 = result.md5
                }
            }

            log.added(job.hint, category: categoryName)
            attachmentsProcessed += 1
            emit("采集中", category: categoryName)

            let downloaded: DownloadedFile
            do {
                downloaded = try await download(job: job, category: category)
            } catch {
                let message = error.localizedDescription
                log.failed("\(job.hint)：下载失败，\(message)", category: categoryName)
                bumpStats(categoryName, runtimes: runtimes, simple: simplePage, found: true, failed: true, page: job.page)
                continue
            }

            if let previous = previousMD5, previous == downloaded.md5, !forceFull {
                log.skipped("\(downloaded.fileName)（内容未变化，跳过）", category: categoryName)
                bumpStats(categoryName, runtimes: runtimes, simple: simplePage, found: true, skipped: true, page: job.page)
                continue
            }

            var content = ""
            var note: String?
            if downloaded.size > 50 * 1024 * 1024 {
                note = "文件过大，已跳过内容识别"
            } else {
                do {
                    let ocrEnabled = config.ocrEnabled
                    let recognition = try await Task.detached(priority: .userInitiated) { [recognizer] in
                        try recognizer.recognize(
                            fileURL: downloaded.fileURL,
                            ext: (downloaded.fileName as NSString).pathExtension.lowercased(),
                            ocrEnabled: ocrEnabled
                        )
                    }.value
                    content = recognition.text
                    note = recognition.note
                } catch {
                    log.failed("\(downloaded.fileName)：识别失败，\(error.localizedDescription)", category: categoryName)
                    bumpStats(categoryName, runtimes: runtimes, simple: simplePage, found: true, failed: true, page: job.page)
                    continue
                }
            }
            if let note = note {
                log.info(note, category: categoryName)
            }

            processedPerCategory[categoryName] = processed + 1
            let record = CollectedRecord(
                categoryName: categoryName,
                pageTitle: job.page.title,
                pageURL: job.page.finalURL.absoluteString,
                attachmentURL: attachmentURL,
                fileName: downloaded.fileName,
                size: downloaded.size,
                content: content,
                md5: downloaded.md5,
                collectedAt: TimeFormat.string()
            )

            let report = await writeOutputs(record: record, fileURL: downloaded.fileURL, category: category, md5: downloaded.md5)

            let successCount = report.successes.count
            let failCount = report.failures.count
            let status: String
            if failCount == 0 {
                status = "成功"
            } else if successCount == 0 {
                status = "失败"
            } else {
                status = "部分失败"
            }
            let reason = report.failures.joined(separator: "；")
            if let (db, rowID) = report.databaseRow {
                db.updateStatus(rowID: rowID, status: status, reason: reason)
            }

            if status == "成功" {
                log.completed(downloaded.fileName, category: categoryName)
                if let store = incremental, store.available {
                    try? store.upsert(
                        category: categoryName,
                        address: attachmentURL,
                        pageURL: job.page.finalURL.absoluteString,
                        md5: params.incrementalRule == .addressAndContent ? downloaded.md5 : nil,
                        time: TimeFormat.string()
                    )
                }
                bumpStats(categoryName, runtimes: runtimes, simple: simplePage, found: true, success: true, page: job.page)
            } else {
                log.failed("\(downloaded.fileName)：\(reason.isEmpty ? "输出失败" : reason)", category: categoryName)
                bumpStats(categoryName, runtimes: runtimes, simple: simplePage, found: true, failed: true, page: job.page)
            }
        }

        if stop.isStopped {
            log.info("采集已停止，已完成的数据已保留")
        }
    }

    private func bumpStats(_ categoryName: String, runtimes: [CategoryRuntime], simple: ParsedPage?, found: Bool = false, skipped: Bool = false, success: Bool = false, failed: Bool = false, page: ParsedPage? = nil) {
        let isDefault = !(runtimes.contains { $0.config.name == categoryName })
        if found {
            if isDefault { defaultsStats.attachmentsFound += 1 } else if let runtime = runtimes.first(where: { $0.config.name == categoryName }) {
                runtime.stats.attachmentsFound += 1
            }
        }
        if skipped {
            if isDefault { defaultsStats.attachmentsSkipped += 1 } else if let runtime = runtimes.first(where: { $0.config.name == categoryName }) {
                runtime.stats.attachmentsSkipped += 1
            }
        }
        if success {
            if isDefault { defaultsStats.attachmentsSuccess += 1 } else if let runtime = runtimes.first(where: { $0.config.name == categoryName }) {
                runtime.stats.attachmentsSuccess += 1
            }
        }
        if failed {
            if isDefault { defaultsStats.attachmentsFailed += 1 } else if let runtime = runtimes.first(where: { $0.config.name == categoryName }) {
                runtime.stats.attachmentsFailed += 1
            }
        }
        _ = page
        _ = simple
    }

    // MARK: - 下载

    private func download(job: AttachmentJob, category: CategoryConfig?) async throws -> DownloadedFile {
        if let hcno = job.attachment.openStdHcno {
            return try await downloadOpenStd(job: job, hcno: hcno)
        }
        return try await downloadDirect(job: job)
    }

    private func downloadDirect(job: AttachmentJob) async throws -> DownloadedFile {
        let url = job.attachment.url
        var result = try await loader.client.get(url, referer: job.page.finalURL)
        if result.status >= 400 {
            throw NetworkError.badStatus(result.status, url.absoluteString)
        }
        if looksHTML(result) {
            result = try await loader.client.get(url, referer: job.page.finalURL)
            if result.status >= 400 {
                throw NetworkError.badStatus(result.status, url.absoluteString)
            }
            if looksHTML(result) {
                throw NetworkError.notAllowedType(result.contentType.isEmpty ? "HTML" : result.contentType, result.data.count)
            }
        }
        guard let ext = allowedExtension(for: url, result: result) else {
            throw NetworkError.notAllowedType(result.contentType.isEmpty ? "未知" : result.contentType, result.data.count)
        }
        let name = fileName(for: job, headers: result.headers, url: url, ext: ext, index: 1)
        return try saveDownloaded(data: result.data, name: name)
    }

    private func downloadOpenStd(job: AttachmentJob, hcno: String) async throws -> DownloadedFile {
        guard let entryURL = OpenStdSite.downloadEntryURL(hcno: hcno),
              let viewURL = OpenStdSite.viewURL(hcno: hcno) else {
            throw NetworkError.invalidURL(job.attachment.url.absoluteString)
        }
        let client = loader.client
        var sessionRebuilt = false

        while true {
            let entry = try await client.get(entryURL, referer: job.page.finalURL)
            if let finalURL = entry.url, finalURL.path.contains("404.jsp") {
                throw refusalError()
            }
            if entry.status >= 400 {
                throw NetworkError.badStatus(entry.status, entryURL.absoluteString)
            }
            let html = entry.text
            if !OpenStdSite.sessionAllowed(html) {
                if !OpenStdSite.requiresCaptcha(html) {
                    throw refusalError()
                }
                if !sessionRebuilt {
                    sessionRebuilt = true
                    log.info("站点要求重新验证，等待 60 秒后重建会话重试", category: nil)
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    client.resetSession()
                    let listReferer = URL(string: OpenStdSite.base + "/bzgk/std/")
                    _ = try? await client.get(job.page.finalURL, referer: listReferer)
                    log.info("已重建会话并重访详情页，重新获取下载入口", category: nil)
                    continue
                }
                throw NetworkError.captcha
            }

            var file = try await client.get(viewURL, referer: entryURL)
            if file.status >= 400 {
                throw NetworkError.badStatus(file.status, viewURL.absoluteString)
            }
            if looksHTML(file) || !isPDF(file.data) {
                file = try await client.get(viewURL, referer: entryURL)
                if file.status >= 400 {
                    throw NetworkError.badStatus(file.status, viewURL.absoluteString)
                }
                if looksHTML(file) || !isPDF(file.data) {
                    if let finalURL = file.url, finalURL.path.contains("404.jsp") { throw refusalError() }
                    if OpenStdSite.requiresCaptcha(file.text) { throw NetworkError.captcha }
                    throw NetworkError.notAllowedType(file.contentType.isEmpty ? "HTML" : file.contentType, file.data.count)
                }
            }

            let fallback = job.hint.isEmpty ? job.page.title : job.hint
            var name = fileName(for: job, headers: file.headers, url: job.attachment.url, ext: "pdf", index: 1, fallbackName: fallback + ".pdf")
            if (name as NSString).pathExtension.isEmpty { name += ".pdf" }
            return try saveDownloaded(data: file.data, name: name)
        }
    }

    private func refusalError() -> NetworkError {
        if !openStdRefusalLogged {
            openStdRefusalLogged = true
            log.info("站点暂时拒绝下载（可能触发访问频率限制），后续下载可能继续失败，建议稍后重试", category: nil)
        }
        return .siteRefused("站点暂时拒绝下载（可能触发访问频率限制，请稍后重试）")
    }

    private func looksHTML(_ result: HTTPResult) -> Bool {
        let type = result.contentType.lowercased()
        if type.contains("text/html") || type.contains("application/xhtml") { return true }
        let prefix = String(data: result.data.prefix(256), encoding: .utf8)?.lowercased() ?? ""
        return prefix.contains("<!doctype html") || prefix.contains("<html")
    }

    private func isPDF(_ data: Data) -> Bool {
        data.starts(with: [0x25, 0x50, 0x44, 0x46])
    }

    private func allowedExtension(for url: URL, result: HTTPResult) -> String? {
        if let ext = Address.allowedExtension(url) { return ext }
        let type = result.contentType.lowercased()
        if type.contains("pdf") { return "pdf" }
        if type.contains("jpeg") { return "jpg" }
        if type.contains("png") { return "png" }
        if type.contains("wordprocessingml") { return "docx" }
        if type.contains("msword") { return "doc" }
        if type.contains("spreadsheetml") { return "xlsx" }
        if type.contains("ms-excel") { return "xls" }
        let cd = result.header("Content-Disposition") ?? ""
        let ext = (cd as NSString).pathExtension.lowercased()
        return ConfigValidator.allowedTypes.contains(ext) ? ext : nil
    }

    private func fileName(for job: AttachmentJob, headers: [AnyHashable: Any], url: URL, ext: String, index: Int, fallbackName: String? = nil) -> String {
        var raw: String?
        for (key, value) in headers {
            if let key = key as? String, key.caseInsensitiveCompare("Content-Disposition") == .orderedSame {
                raw = value as? String
                break
            }
        }
        if let raw = raw, let name = parseContentDisposition(raw), !name.trimmed.isEmpty {
            return ensureExtension(FileUtil.sanitizeFileName(name), ext: ext)
        }
        if let last = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path.split(separator: "/").last {
            let decoded = String(last).removingPercentEncoding ?? String(last)
            if !decoded.isEmpty && decoded != "/" {
                return ensureExtension(FileUtil.sanitizeFileName(decoded), ext: ext)
            }
        }
        let fallback = fallbackName ?? "\(job.page.title)_\(index)"
        return ensureExtension(FileUtil.sanitizeFileName(fallback), ext: ext)
    }

    private func parseContentDisposition(_ value: String) -> String? {
        if let star = HTML.firstCapture(pattern: #"filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)"#, in: value) {
            let decoded = star.trimmingCharacters(in: .whitespacesAndNewlines).removingPercentEncoding
            if let decoded = decoded, !decoded.isEmpty { return decoded }
        }
        if let plain = HTML.firstCapture(pattern: #"filename\s*=\s*"([^"]+)""#, in: value) {
            return plain
        }
        if let plain = HTML.firstCapture(pattern: #"filename\s*=\s*([^;]+)"#, in: value) {
            return plain.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return nil
    }

    private func ensureExtension(_ name: String, ext: String) -> String {
        if (name as NSString).pathExtension.isEmpty {
            return name + "." + ext
        }
        return name
    }

    private func saveDownloaded(data: Data, name: String) throws -> DownloadedFile {
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let target = FileUtil.uniqueFile(in: stagingDir, name: name)
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            throw ObsidianError.writeFailed("附件写入失败：\(error.localizedDescription)")
        }
        let md5 = FileUtil.md5(of: target) ?? ""
        return DownloadedFile(fileURL: target, fileName: target.lastPathComponent, size: Int64(data.count), md5: md5)
    }

    // MARK: - 输出

    private struct OutputReport {
        var successes: [String] = []
        var failures: [String] = []
        var databaseRow: (DatabaseOutput, Int64)?
    }

    private func writeOutputs(record: CollectedRecord, fileURL: URL?, category: CategoryConfig?, md5: String) async -> OutputReport {
        let outputs = (category?.outputMode == .custom) ? (category?.customOutputs ?? OutputSet()) : config.globalOutputs
        var report = OutputReport()

        if !outputs.anyEnabled {
            log.info("未绑定输出目标，仅采集不写入", category: record.categoryName)
            return report
        }

        if outputs.database.enabled {
            do {
                let path = AppPaths.expand(outputs.database.path)
                guard !path.trimmed.isEmpty else { throw SQLiteError.open("未配置数据库文件路径") }
                let db = dbOutputs[path] ?? DatabaseOutput(path: path)
                dbOutputs[path] = db
                let rowID = record.recordType == .pageText
                    ? try db.writePageText(record, forceFull: forceFull)
                    : try db.write(record, forceFull: forceFull)
                report.databaseRow = (db, rowID)
                report.successes.append("数据库")
            } catch {
                report.failures.append("数据库：\(error.localizedDescription)")
            }
        }

        if outputs.feishu.enabled {
            let target = FeishuTarget(appId: outputs.feishu.appId, appToken: outputs.feishu.appToken, tableId: outputs.feishu.tableId)
            if let failure = feishuFailures[target] {
                report.failures.append("飞书：\(failure)")
            } else {
                do {
                    if let client = feishuClients[target] {
                        try await client.createRecord(record: record, uploadAttachment: outputs.feishu.uploadAttachment, fileURL: fileURL, md5: md5)
                        report.successes.append("飞书")
                    } else {
                        let secret = outputs.feishu.appSecret.trimmed
                        guard !secret.isEmpty else {
                            throw FeishuError(message: "应用密钥未填写")
                        }
                        let client = FeishuClient(
                            appId: outputs.feishu.appId,
                            appSecret: secret,
                            appToken: outputs.feishu.appToken,
                            tableId: outputs.feishu.tableId,
                            http: loader.client,
                            log: log
                        )
                        do {
                            try await client.validateFields(requiresPageText: record.recordType == .pageText)
                        } catch {
                            let message = error.localizedDescription
                            feishuFailures[target] = message
                            feishuClients[target] = client
                            throw error
                        }
                        feishuClients[target] = client
                        try await client.createRecord(record: record, uploadAttachment: outputs.feishu.uploadAttachment, fileURL: fileURL, md5: md5)
                        report.successes.append("飞书")
                    }
                } catch {
                    report.failures.append("飞书：\(error.localizedDescription)")
                }
            }
        }

        if outputs.obsidian.enabled {
            do {
                let writer = ObsidianOutput(config: outputs.obsidian, log: log)
                let outcome: ObsidianOutcome
                if record.recordType == .pageText {
                    outcome = try writer.writePageText(record: record, forceFull: forceFull, md5: md5)
                } else if let fileURL = fileURL {
                    outcome = try writer.write(record: record, attachmentFile: fileURL, forceFull: forceFull, md5: md5)
                } else {
                    throw ObsidianError.writeFailed("缺少附件文件")
                }
                switch outcome {
                case .written:
                    report.successes.append("Obsidian")
                case .skipped(let message):
                    log.info(message, category: record.categoryName)
                    report.successes.append("Obsidian")
                }
            } catch {
                report.failures.append("Obsidian：\(error.localizedDescription)")
            }
        }

        return report
    }

    // MARK: - 汇总与进度

    private func buildSummary(runtimes: [CategoryRuntime]) -> String {
        var lines: [String] = []
        var total = CategoryStats()
        var defaultIncluded = false

        func addLine(_ name: String, _ stats: CategoryStats) {
            var line = "\(name) → 页面 访问 \(stats.pagesVisited) / 跳过 \(stats.pagesSkipped) / 失败 \(stats.pagesFailed)；附件 发现 \(stats.attachmentsFound) / 跳过 \(stats.attachmentsSkipped) / 成功 \(stats.attachmentsSuccess) / 失败 \(stats.attachmentsFailed)"
            if stats.pageTextsFound > 0 || stats.pageTextsSkipped > 0 || stats.pageTextsSuccess > 0 || stats.pageTextsFailed > 0 {
                line += "；正文 发现 \(stats.pageTextsFound) / 跳过 \(stats.pageTextsSkipped) / 成功 \(stats.pageTextsSuccess) / 失败 \(stats.pageTextsFailed)"
            }
            lines.append(line)
            total.pagesVisited += stats.pagesVisited
            total.pagesSkipped += stats.pagesSkipped
            total.pagesFailed += stats.pagesFailed
            total.attachmentsFound += stats.attachmentsFound
            total.attachmentsSkipped += stats.attachmentsSkipped
            total.attachmentsSuccess += stats.attachmentsSuccess
            total.attachmentsFailed += stats.attachmentsFailed
            total.pageTextsFound += stats.pageTextsFound
            total.pageTextsSkipped += stats.pageTextsSkipped
            total.pageTextsSuccess += stats.pageTextsSuccess
            total.pageTextsFailed += stats.pageTextsFailed
        }

        for runtime in runtimes {
            addLine(runtime.config.name, runtime.stats)
        }
        if !runtimes.isEmpty {
            if defaultsStats.attachmentsFound > 0 || defaultsStats.pagesVisited > 0 || defaultsStats.pagesFailed > 0 {
                defaultIncluded = true
                addLine("默认分类", defaultsStats)
            }
        } else {
            defaultIncluded = true
            addLine("默认分类", defaultsStats)
        }

        lines.append("全局合计 → 页面 访问 \(total.pagesVisited) / 跳过 \(total.pagesSkipped) / 失败 \(total.pagesFailed)；附件 发现 \(total.attachmentsFound) / 跳过 \(total.attachmentsSkipped) / 成功 \(total.attachmentsSuccess) / 失败 \(total.attachmentsFailed)；正文 发现 \(total.pageTextsFound) / 跳过 \(total.pageTextsSkipped) / 成功 \(total.pageTextsSuccess) / 失败 \(total.pageTextsFailed)")
        if !defaultIncluded && total.attachmentsFound == 0 {
            // 保持输出稳定，未命中时仍有合计行
        }
        return lines.joined(separator: "\n")
    }

    private func failureCount(runtimes: [CategoryRuntime]) -> Int {
        var count = defaultsStats.attachmentsFailed + defaultsStats.pagesFailed + defaultsStats.pageTextsFailed
        for runtime in runtimes {
            count += runtime.stats.attachmentsFailed + runtime.stats.pagesFailed + runtime.stats.pageTextsFailed
        }
        return count
    }

    private func pageErrorMessage(_ error: Error, url: URL) -> String {
        if let network = error as? NetworkError {
            switch network {
            case .badStatus(let code, _):
                if code == 412 || code == 403 || code == 429 || code == 503 {
                    return "页面加载失败：HTTP \(code)（\(url.absoluteString)）。站点启用了访问校验或反爬机制，请勾选「启用动态页面渲染模式」后重试"
                }
                if code < 0 {
                    return "页面加载超时（\(url.absoluteString)）。若该站点启用了访问校验，请勾选「启用动态页面渲染模式」后重试"
                }
                return "页面加载失败：HTTP \(code)（\(url.absoluteString)）"
            case .notAllowedType(let type, let size):
                return "页面内容加载失败：返回非网页内容（\(type)，\(size) 字节），请检查地址"
            case .captcha:
                return "页面要求人工验证，请手动打开该页面完成验证后重试"
            default:
                return "页面内容加载失败：\(network.localizedDescription)（\(url.absoluteString)）"
            }
        }
        return "页面内容加载失败：\(error.localizedDescription)（\(url.absoluteString)）"
    }

    private func emit(_ status: String, category: String = "") {
        let progress = RunProgress(
            status: status,
            category: category,
            pageIndex: currentPageIndex,
            pageTotal: totalPages,
            discoveredPages: 0,
            visitedPages: totalVisits,
            attachmentsProcessed: attachmentsProcessed,
            elapsed: Date().timeIntervalSince(startDate)
        )
        guard let handler = onProgress else { return }
        if Thread.isMainThread {
            handler(progress)
        } else {
            DispatchQueue.main.async {
                handler(progress)
            }
        }
    }
}
