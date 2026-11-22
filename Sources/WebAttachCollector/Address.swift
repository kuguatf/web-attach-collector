import Foundation

enum Address {
    /// R-M5-19 规范化地址：去空白与片段、协议/主机小写、去默认端口、去末尾斜杠、查询参数按名称升序。
    static func normalize(_ raw: String) -> String {
        let text = raw.trimmed
        guard var components = URLComponents(string: text), let scheme = components.scheme, let host = components.host else {
            return text
        }
        let lowerScheme = scheme.lowercased()
        components.scheme = lowerScheme
        components.host = host.lowercased()
        components.fragment = nil
        components.user = nil
        components.password = nil

        if (lowerScheme == "http" && components.port == 80) || (lowerScheme == "https" && components.port == 443) {
            components.port = nil
        }

        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path

        if let query = components.percentEncodedQuery, !query.isEmpty {
            let items = query.split(separator: "&", omittingEmptySubsequences: false).map(String.init)
            let sorted = items.sorted { lhs, rhs in
                let lname = lhs.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? lhs
                let rname = rhs.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rhs
                if lname == rname { return lhs < rhs }
                return lname < rname
            }
            components.percentEncodedQuery = sorted.joined(separator: "&")
        } else {
            components.percentEncodedQuery = nil
        }

        guard let result = components.string else { return text }
        return result
    }

    static func sameDomain(_ a: String, _ b: String) -> Bool {
        guard let ua = URLComponents(string: a), let ub = URLComponents(string: b),
              let sa = ua.scheme?.lowercased(), let sb = ub.scheme?.lowercased(),
              let ha = ua.host?.lowercased(), let hb = ub.host?.lowercased() else {
            return false
        }
        return sa == sb && ha == hb
    }

    static func allowedExtension(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        return ConfigValidator.allowedTypes.contains(ext) ? ext : nil
    }

    static func isIgnorableLink(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return ["mailto", "javascript", "tel", "data", "about"].contains(scheme)
    }

    static func resolve(_ href: String, base: URL) -> URL? {
        let value = href.trimmed
        guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
        guard let url = URL(string: value, relativeTo: base)?.absoluteURL else { return nil }
        return url
    }
}
