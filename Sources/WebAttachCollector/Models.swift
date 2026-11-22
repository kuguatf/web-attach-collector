import Foundation

// MARK: - 枚举

enum IncrementalRule: String, Codable, CaseIterable {
    case address
    case addressAndContent

    var title: String {
        switch self {
        case .address: return "地址校验"
        case .addressAndContent: return "地址+内容校验"
        }
    }
}

enum OutputMode: String, Codable, CaseIterable {
    case inherit
    case custom

    var title: String {
        switch self {
        case .inherit: return "继承全局默认"
        case .custom: return "独立配置"
        }
    }
}

enum DiscoveryMode: String, Codable, CaseIterable {
    case entry
    case pagination
    case crawl
    case both

    var title: String {
        switch self {
        case .entry: return "仅入口页面"
        case .pagination: return "列表翻页"
        case .crawl: return "同域链接遍历"
        case .both: return "翻页+同域遍历"
        }
    }

    var hasPagination: Bool { self == .pagination || self == .both }
    var hasCrawl: Bool { self == .crawl || self == .both }
}

enum PagingMode: String, Codable, CaseIterable {
    case nextLink
    case urlTemplate

    var title: String {
        switch self {
        case .nextLink: return "跟随下一页链接"
        case .urlTemplate: return "URL 页码递增"
        }
    }
}

enum ContentMode: String, Codable, CaseIterable {
    case attachments
    case pageText
    case both

    var title: String {
        switch self {
        case .attachments: return "仅附件"
        case .pageText: return "仅正文"
        case .both: return "正文+附件"
        }
    }

    var includesText: Bool { self == .pageText || self == .both }
    var includesAttachments: Bool { self == .attachments || self == .both }
}

// MARK: - 输出目标配置

struct DatabaseOutputConfig: Codable, Equatable {
    var enabled: Bool = false
    var path: String = ""

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
    }
}

struct FeishuOutputConfig: Codable, Equatable {
    var enabled: Bool = false
    var appId: String = ""
    var appSecret: String = ""
    var appToken: String = ""
    var tableId: String = ""
    var uploadAttachment: Bool = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        appId = try c.decodeIfPresent(String.self, forKey: .appId) ?? ""
        appSecret = try c.decodeIfPresent(String.self, forKey: .appSecret) ?? ""
        appToken = try c.decodeIfPresent(String.self, forKey: .appToken) ?? ""
        tableId = try c.decodeIfPresent(String.self, forKey: .tableId) ?? ""
        uploadAttachment = try c.decodeIfPresent(Bool.self, forKey: .uploadAttachment) ?? false
    }

    var isComplete: Bool {
        !appId.trimmed.isEmpty && !appSecret.trimmed.isEmpty && !appToken.trimmed.isEmpty && !tableId.trimmed.isEmpty
    }
}

struct ObsidianOutputConfig: Codable, Equatable {
    var enabled: Bool = false
    var vaultPath: String = ""
    var notesFolder: String = "网页采集笔记"
    var assetsFolder: String = "assets"
    var tags: String = "网页采集"

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        vaultPath = try c.decodeIfPresent(String.self, forKey: .vaultPath) ?? ""
        notesFolder = try c.decodeIfPresent(String.self, forKey: .notesFolder) ?? "网页采集笔记"
        assetsFolder = try c.decodeIfPresent(String.self, forKey: .assetsFolder) ?? "assets"
        tags = try c.decodeIfPresent(String.self, forKey: .tags) ?? "网页采集"
    }
}

struct OutputSet: Codable, Equatable {
    var database = DatabaseOutputConfig()
    var feishu = FeishuOutputConfig()
    var obsidian = ObsidianOutputConfig()

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        database = try c.decodeIfPresent(DatabaseOutputConfig.self, forKey: .database) ?? DatabaseOutputConfig()
        feishu = try c.decodeIfPresent(FeishuOutputConfig.self, forKey: .feishu) ?? FeishuOutputConfig()
        obsidian = try c.decodeIfPresent(ObsidianOutputConfig.self, forKey: .obsidian) ?? ObsidianOutputConfig()
    }

    var anyEnabled: Bool { database.enabled || feishu.enabled || obsidian.enabled }
}

// MARK: - 智能判定

struct SmartConfig: Codable, Equatable {
    var enabled: Bool = false
    var endpoint: String = ""
    var model: String = ""
    var apiKey: String = ""
    var batchSize: Int = 10
    var maxCalls: Int = 50
    var maxInputChars: Int = 8000
    var promptVersion: String = "m13-v1"
    var locateContent: Bool = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        batchSize = try c.decodeIfPresent(Int.self, forKey: .batchSize) ?? 10
        maxCalls = try c.decodeIfPresent(Int.self, forKey: .maxCalls) ?? 50
        maxInputChars = try c.decodeIfPresent(Int.self, forKey: .maxInputChars) ?? 8000
        promptVersion = try c.decodeIfPresent(String.self, forKey: .promptVersion) ?? "m13-v1"
        locateContent = try c.decodeIfPresent(Bool.self, forKey: .locateContent) ?? false
    }

    /// 兼容用户只填基础地址（如 http://host:1234/v1）的情况。
    var chatCompletionsURL: URL? {
        var text = endpoint.trimmed
        guard !text.isEmpty else { return nil }
        if text.hasSuffix("/chat/completions") { return URL(string: text) }
        if text.hasSuffix("/") { text.removeLast() }
        return URL(string: text + "/chat/completions")
    }
}

// MARK: - 页面发现

struct KeywordScope: Codable, Equatable {
    var title: Bool = true
    var url: Bool = true
    var body: Bool = false

    init() {}
    init(title: Bool, url: Bool, body: Bool) {
        self.title = title; self.url = url; self.body = body
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(Bool.self, forKey: .title) ?? true
        url = try c.decodeIfPresent(Bool.self, forKey: .url) ?? true
        body = try c.decodeIfPresent(Bool.self, forKey: .body) ?? false
    }
    var anySelected: Bool { title || url || body }
}

struct DiscoveryConfig: Codable, Equatable {
    var mode: DiscoveryMode = .entry
    var maxDepth: Int = 2
    var maxPages: Int = 50
    var pageKeywords: String = ""
    var scope = KeywordScope()
    var mustInclude: String = ""
    var mustExclude: String = ""
    var pagingMode: PagingMode = .nextLink
    var nextLinkWords: String = "下一页,下页,后一页,next,›,»"
    var pageTemplate: String = ""
    var startPage: Int = 1
    var maxPage: Int = 20

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(DiscoveryMode.self, forKey: .mode) ?? .entry
        maxDepth = try c.decodeIfPresent(Int.self, forKey: .maxDepth) ?? 2
        maxPages = try c.decodeIfPresent(Int.self, forKey: .maxPages) ?? 50
        pageKeywords = try c.decodeIfPresent(String.self, forKey: .pageKeywords) ?? ""
        scope = try c.decodeIfPresent(KeywordScope.self, forKey: .scope) ?? KeywordScope()
        mustInclude = try c.decodeIfPresent(String.self, forKey: .mustInclude) ?? ""
        mustExclude = try c.decodeIfPresent(String.self, forKey: .mustExclude) ?? ""
        pagingMode = try c.decodeIfPresent(PagingMode.self, forKey: .pagingMode) ?? .nextLink
        nextLinkWords = try c.decodeIfPresent(String.self, forKey: .nextLinkWords) ?? "下一页,下页,后一页,next,›,»"
        pageTemplate = try c.decodeIfPresent(String.self, forKey: .pageTemplate) ?? ""
        startPage = try c.decodeIfPresent(Int.self, forKey: .startPage) ?? 1
        maxPage = try c.decodeIfPresent(Int.self, forKey: .maxPage) ?? 20
    }

    var hasPagination: Bool { mode.hasPagination }
    var hasCrawl: Bool { mode.hasCrawl }
}

// MARK: - 参数覆盖

struct OverrideConfig: Codable, Equatable {
    var interval: Double? = nil
    var timeout: Double? = nil
    var maxAttachments: Int? = nil
    var incrementalRule: IncrementalRule? = nil
    var dynamicRendering: Bool? = nil

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interval = try c.decodeIfPresent(Double.self, forKey: .interval)
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout)
        maxAttachments = try c.decodeIfPresent(Int.self, forKey: .maxAttachments)
        incrementalRule = try c.decodeIfPresent(IncrementalRule.self, forKey: .incrementalRule)
        dynamicRendering = try c.decodeIfPresent(Bool.self, forKey: .dynamicRendering)
    }
}

// MARK: - 分类

struct CategoryConfig: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var enabled: Bool = true
    var pagesText: String = ""
    var attachmentKeywords: String = ""
    var contentMode: ContentMode = .attachments
    var outputMode: OutputMode = .inherit
    var customOutputs = OutputSet()
    var overrideEnabled: Bool = false
    var overrides = OverrideConfig()
    var discovery = DiscoveryConfig()

    init() {}
    init(name: String) { self.name = name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        pagesText = try c.decodeIfPresent(String.self, forKey: .pagesText) ?? ""
        attachmentKeywords = try c.decodeIfPresent(String.self, forKey: .attachmentKeywords) ?? ""
        contentMode = try c.decodeIfPresent(ContentMode.self, forKey: .contentMode) ?? .attachments
        outputMode = try c.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? .inherit
        customOutputs = try c.decodeIfPresent(OutputSet.self, forKey: .customOutputs) ?? OutputSet()
        overrideEnabled = try c.decodeIfPresent(Bool.self, forKey: .overrideEnabled) ?? false
        overrides = try c.decodeIfPresent(OverrideConfig.self, forKey: .overrides) ?? OverrideConfig()
        discovery = try c.decodeIfPresent(DiscoveryConfig.self, forKey: .discovery) ?? DiscoveryConfig()
    }

    var pageURLs: [String] {
        pagesText.components(separatedBy: .newlines)
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
    }

    var attachmentKeywordList: [String] {
        attachmentKeywords.components(separatedBy: ",")
            .map { $0.trimmed.lowercased() }
            .filter { !$0.isEmpty }
    }
}

// MARK: - 全局配置

struct AppConfig: Codable, Equatable {
    var version: Int = 1
    var targetURL: String = ""
    var userAgent: String = ConfigDefaults.userAgent
    var stagingDir: String = AppPaths.attachmentsDir.path
    var requestInterval: Double = 1
    var requestTimeout: Double = 15
    var maxAttachments: Int = 200
    var dynamicRendering: Bool = false
    var ocrEnabled: Bool = true
    var smart = SmartConfig()
    var incrementalEnabled: Bool = true
    var incrementalRule: IncrementalRule = .address
    var incrementalPath: String = AppPaths.incrementalDB.path
    var globalOutputs = OutputSet()
    var categories: [CategoryConfig] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        targetURL = try c.decodeIfPresent(String.self, forKey: .targetURL) ?? ""
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent) ?? ConfigDefaults.userAgent
        stagingDir = try c.decodeIfPresent(String.self, forKey: .stagingDir) ?? AppPaths.attachmentsDir.path
        requestInterval = try c.decodeIfPresent(Double.self, forKey: .requestInterval) ?? 1
        requestTimeout = try c.decodeIfPresent(Double.self, forKey: .requestTimeout) ?? 15
        maxAttachments = try c.decodeIfPresent(Int.self, forKey: .maxAttachments) ?? 200
        dynamicRendering = try c.decodeIfPresent(Bool.self, forKey: .dynamicRendering) ?? false
        ocrEnabled = try c.decodeIfPresent(Bool.self, forKey: .ocrEnabled) ?? true
        smart = try c.decodeIfPresent(SmartConfig.self, forKey: .smart) ?? SmartConfig()
        incrementalEnabled = try c.decodeIfPresent(Bool.self, forKey: .incrementalEnabled) ?? true
        incrementalRule = try c.decodeIfPresent(IncrementalRule.self, forKey: .incrementalRule) ?? .address
        incrementalPath = try c.decodeIfPresent(String.self, forKey: .incrementalPath) ?? AppPaths.incrementalDB.path
        globalOutputs = try c.decodeIfPresent(OutputSet.self, forKey: .globalOutputs) ?? OutputSet()
        categories = try c.decodeIfPresent([CategoryConfig].self, forKey: .categories) ?? []
    }

    func category(named name: String) -> CategoryConfig? {
        categories.first { $0.name == name }
    }

    func category(id: UUID) -> CategoryConfig? {
        categories.first { $0.id == id }
    }
}

enum ConfigDefaults {
    static var userAgent: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let safari = max(17, v.majorVersion)
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safari).0 Safari/605.1.15"
    }
}

// MARK: - 有效参数

struct EffectiveParameters {
    let interval: Double
    let timeout: Double
    let maxAttachments: Int
    let incrementalRule: IncrementalRule
    let dynamicRendering: Bool
    let contentMode: ContentMode

    init(global: AppConfig, category: CategoryConfig?) {
        interval = category?.overrideEnabled == true ? (category?.overrides.interval ?? global.requestInterval) : global.requestInterval
        timeout = category?.overrideEnabled == true ? (category?.overrides.timeout ?? global.requestTimeout) : global.requestTimeout
        maxAttachments = category?.overrideEnabled == true ? (category?.overrides.maxAttachments ?? global.maxAttachments) : global.maxAttachments
        incrementalRule = category?.overrideEnabled == true ? (category?.overrides.incrementalRule ?? global.incrementalRule) : global.incrementalRule
        dynamicRendering = category?.overrideEnabled == true ? (category?.overrides.dynamicRendering ?? global.dynamicRendering) : global.dynamicRendering
        contentMode = category?.contentMode ?? .attachments
    }
}

// MARK: - 校验

enum ConfigValidator {
    static let allowedTypes = ["pdf", "doc", "docx", "xls", "xlsx", "jpg", "jpeg", "png"]

    static func firstError(_ config: AppConfig, llmKey: String?) -> String? {
        if config.categories.isEmpty {
            if config.targetURL.trimmed.isEmpty { return "请先填写采集目标地址" }
            if !config.globalOutputs.anyEnabled { return "请至少选择一个输出目标" }
        }
        if config.requestInterval < 0 || config.requestInterval > 60 { return "请求间隔需在 0–60 秒之间" }
        if config.requestTimeout < 5 || config.requestTimeout > 120 { return "请求超时需在 5–120 秒之间" }
        if config.maxAttachments < 1 { return "最大采集附件数需大于 0" }
        if config.stagingDir.trimmed.isEmpty { return "请选择附件暂存目录" }
        if config.categories.count > 50 { return "分类数量已达上限 50 个，请先删除或合并" }

        var seen = Set<String>()
        for category in config.categories {
            let name = category.name.trimmed
            if name.isEmpty { return "请填写分类名称" }
            if name.count > 32 { return "分类名称需在 1–32 字符之间" }
            if seen.contains(name) { return "分类名称「\(name)」已存在，请更换" }
            seen.insert(name)
            if category.enabled && category.pageURLs.isEmpty { return "分类「\(name)」未填写页面地址" }
            if category.pageURLs.count > 50 { return "分类「\(name)」页面地址已达上限 50 个" }
            let d = category.discovery
            if d.maxDepth < 1 || d.maxDepth > 5 { return "最大深度需在 1–5 之间" }
            if d.maxPages < 1 || d.maxPages > 500 { return "最大发现页面数需在 1–500 之间" }
            if !d.scope.anySelected { return "页面关键词匹配范围至少选择一项" }
            if d.hasPagination && d.pagingMode == .urlTemplate {
                if !d.pageTemplate.contains("{页码}") { return "页码模板必须包含 {页码}" }
                if d.startPage < 1 || d.startPage > 500 || d.maxPage < d.startPage || d.maxPage > 500 {
                    return "页码范围无效：起始页码需在 1–500 之间，最大页码不得小于起始页码"
                }
                for page in category.pageURLs {
                    guard let base = URL(string: page), let template = URL(string: d.pageTemplate.replacingOccurrences(of: "{页码}", with: "\(d.startPage)")) else {
                        return "页码模板必须与入口页面同域"
                    }
                    if !Address.sameDomain(base.absoluteString, template.absoluteString) {
                        return "页码模板必须与入口页面同域"
                    }
                }
            }
            if category.outputMode == .custom {
                if category.customOutputs.feishu.enabled && !category.customOutputs.feishu.isComplete {
                    return "飞书配置不完整，请填写全部四项参数"
                }
            }
        }

        if config.globalOutputs.feishu.enabled && !config.globalOutputs.feishu.isComplete {
            return "飞书配置不完整，请填写 App ID、App Secret、App Token 与 table_id"
        }
        if config.smart.enabled {
            if config.smart.endpoint.trimmed.isEmpty { return "启用智能判定时，服务地址不能为空" }
            if config.smart.model.trimmed.isEmpty { return "启用智能判定时，模型名称不能为空" }
            if (llmKey ?? "").isEmpty { return "大模型 API Key 未填写，请在「① 采集设置」中填写" }
            if config.smart.batchSize < 5 || config.smart.batchSize > 20 { return "批量大小需在 5–20 之间" }
            if config.smart.maxCalls < 1 || config.smart.maxCalls > 500 { return "单次任务最大调用次数需在 1–500 之间" }
            if config.smart.maxInputChars < 500 || config.smart.maxInputChars > 20000 { return "单次调用最大输入字符需在 500–20000 之间" }
        }
        if config.smart.locateContent {
            if config.smart.endpoint.trimmed.isEmpty { return "启用智能正文定位时，服务地址不能为空" }
            if config.smart.model.trimmed.isEmpty { return "启用智能正文定位时，模型名称不能为空" }
            if (llmKey ?? "").isEmpty { return "大模型 API Key 未填写，请在「① 采集设置」中填写" }
        }
        return nil
    }

    /// R-M5-12：返回未绑定输出目标的分类（独立配置且三项全未勾选）。
    static func unboundCategories(_ config: AppConfig) -> [CategoryConfig] {
        config.categories.filter { $0.enabled && $0.outputMode == .custom && !$0.customOutputs.anyEnabled }
    }
}

// MARK: - 采集方案（Site Plan）

enum SiteFieldAttr: String, Codable, CaseIterable {
    case text
    case href
    case src
    case onclick
    case tagname
    case title
    case datetime

    var title: String {
        switch self {
        case .text: return "文本"
        case .href: return "href"
        case .src: return "src"
        case .onclick: return "onclick"
        case .tagname: return "tagname"
        case .title: return "title"
        case .datetime: return "datetime"
        }
    }
}

struct SiteField: Codable, Equatable {
    var selector: String = ""
    var attr: SiteFieldAttr = .text
    var regex: String = ""
    var trim: Bool = true

    init() {}
    init(selector: String, attr: SiteFieldAttr = .text, regex: String = "", trim: Bool = true) {
        self.selector = selector
        self.attr = attr
        self.regex = regex
        self.trim = trim
    }
}

struct SiteListFields: Codable, Equatable {
    var title = SiteField(selector: "a")
    var url = SiteField(selector: "a", attr: .href)
    var date = SiteField(selector: "")

    init() {}
}

struct SiteListPlan: Codable, Equatable {
    var item: String = ""
    var fields = SiteListFields()

    init() {}
}

enum SitePagingType: String, Codable, CaseIterable {
    case none
    case link
    case template
    case param

    var title: String {
        switch self {
        case .none: return "不翻页"
        case .link: return "跟随链接"
        case .template: return "页码模板"
        case .param: return "参数页码"
        }
    }
}

struct SiteParamPaging: Codable, Equatable {
    var base: String = ""
    var name: String = "page"
    var start: Int = 2
    var end: Int = 20

    init() {}
}

struct SitePagingPlan: Codable, Equatable {
    var type: SitePagingType = .none
    var selector: String = ""
    var urlFrom: SiteFieldAttr = .href
    var template: String = ""
    var param = SiteParamPaging()
    var maxPages: Int = 20
    var stopWhen: String = ""

    init() {}
}

struct SiteDetailPlan: Codable, Equatable {
    var content: [String] = []
    var exclude: [String] = []

    init() {}
}

struct SiteAttachmentPlan: Codable, Equatable {
    var linkSelector: String = "a[href]"
    var extensions: [String] = ConfigValidator.allowedTypes

    init() {}
}

struct SitePlanMeta: Codable, Equatable {
    var model: String = ""
    var promptVersion: String = "site-v1"
    var createdAt: String = ""
    var confirmed: Bool = false

    init() {}
}

struct SitePlan: Codable, Equatable {
    var version: String = "site-plan-v1"
    var host: String = ""
    var pathPattern: String = ""
    var entry: String = ""
    var list = SiteListPlan()
    var paging = SitePagingPlan()
    var detail = SiteDetailPlan()
    var attachments = SiteAttachmentPlan()
    var meta = SitePlanMeta()

    init() {}
}

extension SiteField {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selector = try c.decodeIfPresent(String.self, forKey: .selector) ?? ""
        attr = try c.decodeIfPresent(SiteFieldAttr.self, forKey: .attr) ?? .text
        regex = try c.decodeIfPresent(String.self, forKey: .regex) ?? ""
        trim = try c.decodeIfPresent(Bool.self, forKey: .trim) ?? true
    }
}

extension SiteListFields {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(SiteField.self, forKey: .title) ?? SiteField(selector: "a")
        url = try c.decodeIfPresent(SiteField.self, forKey: .url) ?? SiteField(selector: "a", attr: .href)
        date = try c.decodeIfPresent(SiteField.self, forKey: .date) ?? SiteField(selector: "")
    }
}

extension SiteListPlan {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decodeIfPresent(String.self, forKey: .item) ?? ""
        fields = try c.decodeIfPresent(SiteListFields.self, forKey: .fields) ?? SiteListFields()
    }
}

extension SiteParamPaging {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = try c.decodeIfPresent(String.self, forKey: .base) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "page"
        start = try c.decodeIfPresent(Int.self, forKey: .start) ?? 2
        end = try c.decodeIfPresent(Int.self, forKey: .end) ?? 20
    }
}

extension SitePagingPlan {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(SitePagingType.self, forKey: .type) ?? .none
        selector = try c.decodeIfPresent(String.self, forKey: .selector) ?? ""
        urlFrom = try c.decodeIfPresent(SiteFieldAttr.self, forKey: .urlFrom) ?? .href
        template = try c.decodeIfPresent(String.self, forKey: .template) ?? ""
        param = try c.decodeIfPresent(SiteParamPaging.self, forKey: .param) ?? SiteParamPaging()
        maxPages = try c.decodeIfPresent(Int.self, forKey: .maxPages) ?? 20
        stopWhen = try c.decodeIfPresent(String.self, forKey: .stopWhen) ?? ""
    }
}

extension SiteDetailPlan {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent([String].self, forKey: .content) ?? []
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
    }
}

extension SiteAttachmentPlan {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        linkSelector = try c.decodeIfPresent(String.self, forKey: .linkSelector) ?? "a[href]"
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions) ?? ConfigValidator.allowedTypes
    }
}

extension SitePlanMeta {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        promptVersion = try c.decodeIfPresent(String.self, forKey: .promptVersion) ?? "site-v1"
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
    }
}

extension SitePlan {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "site-plan-v1"
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        pathPattern = try c.decodeIfPresent(String.self, forKey: .pathPattern) ?? ""
        entry = try c.decodeIfPresent(String.self, forKey: .entry) ?? ""
        list = try c.decodeIfPresent(SiteListPlan.self, forKey: .list) ?? SiteListPlan()
        paging = try c.decodeIfPresent(SitePagingPlan.self, forKey: .paging) ?? SitePagingPlan()
        detail = try c.decodeIfPresent(SiteDetailPlan.self, forKey: .detail) ?? SiteDetailPlan()
        attachments = try c.decodeIfPresent(SiteAttachmentPlan.self, forKey: .attachments) ?? SiteAttachmentPlan()
        meta = try c.decodeIfPresent(SitePlanMeta.self, forKey: .meta) ?? SitePlanMeta()
    }
}

// MARK: - 小工具

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum TimeFormat {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func string(_ date: Date = Date()) -> String { formatter.string(from: date) }

    static func logTime(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone.current
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
