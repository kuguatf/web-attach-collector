import Foundation

struct RawAttachment {
    let url: URL
    let nameHint: String?
    let openStdHcno: String?
}

struct ResolvedAnchor {
    let url: URL
    let text: String
    let ariaLabel: String
    let title: String
}

struct ParsedPage {
    let requestedURL: URL
    let finalURL: URL
    let normalized: String
    let title: String
    let text: String
    let contentText: String
    let sourceHTML: String?
    let attachments: [RawAttachment]
    let links: [URL]
    let anchors: [ResolvedAnchor]
    let isHTML: Bool
}

enum OpenStdSite {
    static let base = "https://openstd.samr.gov.cn"

    static func isSite(_ url: URL) -> Bool {
        (url.host ?? "").lowercased() == "openstd.samr.gov.cn"
    }

    static func hcno(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name.lowercased() == "hcno" }?.value
    }

    static func detailURL(hcno: String) -> URL? {
        URL(string: base + "/bzgk/std/newGbInfo?hcno=" + hcno)
    }

    static func downloadEntryURL(hcno: String) -> URL? {
        URL(string: base + "/bzgk/std/showGb?type=download&hcno=" + hcno + "&request_locale=zh")
    }

    static func viewURL(hcno: String) -> URL? {
        URL(string: base + "/bzgk/std/viewGb?hcno=" + hcno)
    }

    static func listDetailLinks(in html: String) -> [URL] {
        let hcnos = HTML.allCaptures(pattern: #"showInfo\(\s*['"]([0-9A-Fa-f]+)['"]\s*\)"#, in: html)
        var result: [URL] = []
        var seen = Set<String>()
        for hcno in hcnos {
            guard !seen.contains(hcno), let url = detailURL(hcno: hcno) else { continue }
            seen.insert(hcno)
            result.append(url)
        }
        return result
    }

    static func isDetailPage(_ url: URL) -> Bool {
        url.path.contains("newGbInfo") && hcno(from: url) != nil
    }

    /// 详情页是否提供全文下载入口；返回 (hcno, 可下载, 原因)。
    static func downloadEntry(in html: String, pageURL: URL) -> (hcno: String, downloadable: Bool, reason: String)? {
        guard let hcno = hcno(from: pageURL) else { return nil }
        let body = html
        var downloadable = false
        let buttons = HTML.allCaptures(pattern: #"(<button[^>]*>)"#, in: body, options: [.caseInsensitive])
        for tag in buttons {
            guard tag.range(of: "xz_btn", options: .caseInsensitive) != nil else { continue }
            guard let value = HTML.attribute("data-value", in: tag), !value.isEmpty else { continue }
            downloadable = true
            break
        }
        if downloadable { return (hcno, true, "") }
        var reason = "详情页未提供下载入口"
        if let span = HTML.firstCapture(pattern: #"<span[^>]*class="[^"]*text-danger[^"]*"[^>]*>([\s\S]*?)</span>"#, in: body, options: [.caseInsensitive]) {
            let text = HTML.stripTags(span).trimmed
            if !text.isEmpty { reason = text }
        }
        return (hcno, false, reason)
    }

    static func sessionAllowed(_ html: String) -> Bool {
        guard let value = HTML.firstCapture(pattern: #"var isValid = '(true|false)'"#, in: html) else {
            return false
        }
        return value == "true"
    }

    static func requiresCaptcha(_ html: String) -> Bool {
        html.contains("验证码") || html.range(of: "captcha", options: .caseInsensitive) != nil
    }
}

enum PageExtractor {
    static func parse(html: String, requested: URL, finalURL: URL, keepHTML: Bool = false) -> ParsedPage {
        let base = HTML.baseHref(html).flatMap { URL(string: $0, relativeTo: finalURL)?.absoluteURL } ?? finalURL
        let rawLinks = HTML.links(html)
        var links: [URL] = []
        var anchors: [ResolvedAnchor] = []
        var seenLinks = Set<String>()
        var attachments: [RawAttachment] = []
        var seenAttachments = Set<String>()

        func appendLink(_ url: URL) {
            let key = Address.normalize(url.absoluteString)
            if seenLinks.insert(key).inserted { links.append(url) }
        }

        for link in rawLinks {
            guard let resolved = Address.resolve(link.href, base: base) else { continue }
            if Address.isIgnorableLink(resolved) { continue }
            anchors.append(ResolvedAnchor(url: resolved, text: link.text, ariaLabel: link.ariaLabel, title: link.title))
            if let ext = Address.allowedExtension(resolved) {
                _ = ext
                let key = Address.normalize(resolved.absoluteString)
                if seenAttachments.insert(key).inserted {
                    let hint = link.text.isEmpty ? link.title : link.text
                    attachments.append(RawAttachment(url: resolved, nameHint: hint.isEmpty ? nil : hint, openStdHcno: nil))
                }
                continue
            }
            appendLink(resolved)
        }

        if OpenStdSite.isSite(finalURL) {
            // 列表页结果使用脚本 showInfo('HCNO')，补充为详情页链接。
            for detail in OpenStdSite.listDetailLinks(in: html) {
                appendLink(detail)
                anchors.append(ResolvedAnchor(url: detail, text: "", ariaLabel: "", title: ""))
            }
            if OpenStdSite.isDetailPage(finalURL), let entry = OpenStdSite.downloadEntry(in: html, pageURL: finalURL),
               entry.downloadable, let downloadURL = OpenStdSite.downloadEntryURL(hcno: entry.hcno) {
                let key = Address.normalize(downloadURL.absoluteString)
                if seenAttachments.insert(key).inserted {
                    let standardTitle = HTML.firstCapture(pattern: #"<title[^>]*>([\s\S]*?)</title>"#, in: html, options: [.caseInsensitive]).map { HTML.stripTags($0).trimmed }
                    attachments.append(RawAttachment(url: downloadURL, nameHint: standardTitle, openStdHcno: entry.hcno))
                }
            }
        }

        let title = HTML.title(html) ?? "未命名页面"
        let text = HTML.visibleText(html)
        return ParsedPage(
            requestedURL: requested,
            finalURL: finalURL,
            normalized: Address.normalize(finalURL.absoluteString),
            title: title,
            text: text,
            contentText: HTML.pageText(html),
            sourceHTML: keepHTML ? html : nil,
            attachments: attachments,
            links: links,
            anchors: anchors,
            isHTML: true
        )
    }
}

final class PageLoader {
    private let config: AppConfig
    private let log: LogStore
    private let limiter: RequestLimiter
    let client: HTTPClient
    private var renderer: WebPageRenderer?
    private var cache: [String: ParsedPage] = [:]

    init(config: AppConfig, log: LogStore, limiter: RequestLimiter) {
        self.config = config
        self.log = log
        self.limiter = limiter
        self.client = HTTPClient(
            userAgent: config.userAgent,
            timeout: config.requestTimeout,
            limiter: limiter,
            interval: { config.requestInterval }
        )
    }

    func cached(_ url: URL) -> ParsedPage? {
        cache[Address.normalize(url.absoluteString)]
    }

    func load(_ url: URL, useDynamic: Bool, keepHTML: Bool? = nil) async throws -> ParsedPage {
        let key = Address.normalize(url.absoluteString)
        let retainHTML = keepHTML ?? config.smart.locateContent
        if let cached = cache[key], !(retainHTML && cached.sourceHTML == nil) { return cached }

        let page: ParsedPage
        if useDynamic {
            let renderer = await mainRenderer()
            let rendered = try await renderer.render(url: url, timeout: max(config.requestTimeout, 20))
            page = PageExtractor.parse(html: rendered.html, requested: url, finalURL: rendered.url, keepHTML: retainHTML)
        } else {
            let result = try await client.get(url)
            guard result.status < 400 else {
                throw NetworkError.badStatus(result.status, url.absoluteString)
            }
            guard result.isHTML else {
                throw NetworkError.notAllowedType(result.contentType, result.data.count)
            }
            let html = result.text
            guard !html.trimmed.isEmpty else { throw NetworkError.emptyResponse }
            page = PageExtractor.parse(html: html, requested: url, finalURL: result.url ?? url, keepHTML: retainHTML)
        }

        cache[key] = page
        cache[page.normalized] = page
        return page
    }

    func shutdown() {
        client.invalidate()
    }

    @MainActor
    private func mainRenderer() -> WebPageRenderer {
        if let renderer { return renderer }
        let created = WebPageRenderer()
        renderer = created
        return created
    }
}

import WebKit

struct RenderedPage {
    let html: String
    let url: URL
    let title: String
}

@MainActor
final class WebPageRenderer: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<RenderedPage, Error>?
    private var webView: WKWebView?
    private var finished = false
    private var lastStatus = 0
    private var deadline = Date()
    private var pollGeneration = 0
    private var contentWaitStart = Date()

    /// 同一次运行内复用 Cookie，站点反爬校验只需通过一次。
    private let dataStore = WKWebsiteDataStore.nonPersistent()

    func render(url: URL, timeout: Double) async throws -> RenderedPage {
        finished = false
        lastStatus = 0
        pollGeneration &+= 1
        deadline = Date().addingTimeInterval(max(timeout, 30))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        view.navigationDelegate = self
        webView = view

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            view.load(URLRequest(url: url))
            DispatchQueue.main.asyncAfter(deadline: .now() + max(timeout, 30)) { [weak self] in
                guard let self = self, !self.finished else { return }
                let code = self.lastStatus >= 400 ? self.lastStatus : -1001
                self.finish(.failure(NetworkError.badStatus(code, url.absoluteString)))
            }
        }
    }

    private func finish(_ result: Result<RenderedPage, Error>) {
        guard !finished else { return }
        finished = true
        pollGeneration &+= 1
        let continuation = self.continuation
        self.continuation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation?.resume(with: result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse {
            lastStatus = http.statusCode
        } else {
            lastStatus = 0
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        contentWaitStart = Date()
        pollForContent(generation: pollGeneration)
    }

    /// 等页面真正可用再抓取：跳过反爬校验页（HTTP 4xx + 挑战脚本）与空白页。
    private func pollForContent(generation: Int) {
        guard !finished, generation == pollGeneration else { return }
        guard let view = webView else { return }
        if Date() >= deadline {
            let code = lastStatus >= 400 ? lastStatus : -1001
            finish(.failure(NetworkError.badStatus(code, view.url?.absoluteString ?? "")))
            return
        }

        let probe = """
        (function(){
          var html = document.documentElement ? document.documentElement.outerHTML : "";
          var body = document.body ? document.body.innerText : "";
          return JSON.stringify({
            ready: document.readyState,
            text: body.length,
            html: html.length,
            challenge: /\\$_ts|_\\$\\$D|__jsluid|加速乐/.test(html)
          });
        })()
        """
        view.evaluateJavaScript(probe) { [weak self] value, _ in
            Task { @MainActor in
                guard let self = self, !self.finished, generation == self.pollGeneration else { return }
                var ready = false
                var textLength = 0
                var challenge = true
                if let json = value as? String, let data = json.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    ready = (object["ready"] as? String) == "complete"
                    textLength = object["text"] as? Int ?? 0
                    challenge = object["challenge"] as? Bool ?? true
                }

                // 优先等正文文本出现；纯图片页等 5 秒仍无文本时按现有 DOM 抓取。
                let waitedLongEnough = Date().timeIntervalSince(self.contentWaitStart) >= 5
                let pending = self.lastStatus >= 400 || challenge || !ready || (textLength < 10 && !waitedLongEnough)
                if pending {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.pollForContent(generation: generation)
                    }
                    return
                }

                let finalURL = view.url ?? URL(string: "about:blank")!
                view.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] value, error in
                    Task { @MainActor in
                        guard let self = self, !self.finished, generation == self.pollGeneration else { return }
                        if let html = value as? String, !html.isEmpty {
                            self.finish(.success(RenderedPage(html: html, url: finalURL, title: view.title ?? "")))
                        } else {
                            self.finish(.failure(error ?? NetworkError.emptyResponse))
                        }
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}
