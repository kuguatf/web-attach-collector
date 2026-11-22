import Foundation
import CoreFoundation

actor RequestLimiter {
    private var lastRequest = Date.distantPast

    func wait(interval: Double) async {
        guard interval > 0 else {
            lastRequest = Date()
            return
        }
        let elapsed = Date().timeIntervalSince(lastRequest)
        if elapsed < interval {
            let nanos = UInt64((interval - elapsed) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        }
        lastRequest = Date()
    }
}

enum NetworkError: LocalizedError {
    case invalidURL(String)
    case badStatus(Int, String)
    case emptyResponse
    case notAllowedType(String, Int)
    case captcha
    case siteRefused(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value): return "地址无效：\(value)"
        case .badStatus(let code, let url): return "请求失败：HTTP \(code)（\(url)）"
        case .emptyResponse: return "响应内容为空"
        case .notAllowedType(let type, let size): return "返回非允许类型（\(type)，\(size) 字节）"
        case .captcha: return "站点要求人工验证"
        case .siteRefused(let detail): return detail
        case .cancelled: return "任务已停止"
        }
    }
}

struct HTTPResult {
    let url: URL?
    let status: Int
    let headers: [AnyHashable: Any]
    let data: Data

    func header(_ name: String) -> String? {
        for (key, value) in headers {
            if let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame {
                return value as? String
            }
        }
        return nil
    }

    var contentType: String {
        header("Content-Type") ?? ""
    }

    var isHTML: Bool {
        let type = contentType.lowercased()
        return type.contains("text/html") || type.contains("application/xhtml") || type.isEmpty
    }

    var encoding: String.Encoding {
        let type = contentType.lowercased()
        if let range = type.range(of: "charset=") {
            var charset = String(type[range.upperBound...])
            if let semi = charset.firstIndex(of: ";") { charset = String(charset[..<semi]) }
            charset = charset.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
            if let enc = HTTPResult.encoding(named: charset) { return enc }
        }
        // 从 HTML meta 中探测
        if let prefix = String(data: data.prefix(4096), encoding: .isoLatin1)?.lowercased() {
            for pattern in ["charset=\"", "charset='", "charset="] {
                if let range = prefix.range(of: pattern) {
                    var value = String(prefix[range.upperBound...])
                    let terminators = ["\"", "'", ">", ";", " "]
                    if let idx = value.firstIndex(where: { terminators.contains(String($0)) }) {
                        value = String(value[..<idx])
                    }
                    if let enc = HTTPResult.encoding(named: value) { return enc }
                }
            }
        }
        return .utf8
    }

    var text: String {
        if let string = String(data: data, encoding: encoding) { return string }
        if let string = String(data: data, encoding: .utf8) { return string }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func encoding(named name: String) -> String.Encoding? {
        switch name.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "gbk", "gb2312", "gb18030", "x-gbk": return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "big5": return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        case "iso-8859-1", "latin1": return .isoLatin1
        default: return nil
        }
    }
}

final class HTTPClient {
    private var session: URLSession
    private let userAgent: String
    private let timeout: Double
    private let limiter: RequestLimiter
    private let intervalProvider: () -> Double

    init(userAgent: String, timeout: Double, limiter: RequestLimiter, interval: @escaping () -> Double) {
        self.userAgent = userAgent.trimmed.isEmpty ? ConfigDefaults.userAgent : userAgent
        self.timeout = timeout
        self.limiter = limiter
        self.intervalProvider = interval
        self.session = HTTPClient.makeSession(userAgent: self.userAgent, timeout: timeout)
    }

    private static func makeSession(userAgent: String, timeout: Double) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout * 4, 120)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,application/pdf,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"
        ]
        return URLSession(configuration: configuration)
    }

    /// R-M3-11：重建会话（仅用于站点按会话限制，不破解验证码）。
    func resetSession() {
        session.configuration.httpCookieStorage?.removeCookies(since: .distantPast)
        session.invalidateAndCancel()
        URLCache.shared.removeAllCachedResponses()
        session = HTTPClient.makeSession(userAgent: userAgent, timeout: timeout)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func get(_ url: URL, referer: URL? = nil, extraHeaders: [String: String] = [:]) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let referer = referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        return try await perform(request)
    }

    func postJSON(_ url: URL, body: Data, extraHeaders: [String: String] = [:]) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        return try await perform(request)
    }

    func postMultipart(_ url: URL, body: Data, boundary: String, extraHeaders: [String: String] = [:]) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> HTTPResult {
        await limiter.wait(interval: intervalProvider())
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NetworkError.emptyResponse
            }
            return HTTPResult(url: http.url, status: http.statusCode, headers: http.allHeaderFields, data: data)
        } catch let error as URLError {
            if error.code == .cancelled { throw NetworkError.cancelled }
            if error.code == .timedOut {
                throw NetworkError.badStatus(-1001, request.url?.absoluteString ?? "")
            }
            throw NetworkError.siteRefused("网络请求失败（错误码 \(error.code.rawValue)：\(error.localizedDescription)）")
        }
    }
}
