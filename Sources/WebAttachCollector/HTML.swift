import Foundation

struct HTMLLink {
    let href: String
    let text: String
    let ariaLabel: String
    let title: String
}

enum HTML {
    private static let entityMap: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "middot": "·", "copy": "©",
        "reg": "®", "trade": "™", "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’",
        "laquo": "«", "raquo": "»", "times": "×", "divide": "÷", "deg": "°",
        "plusmn": "±", "para": "¶", "sect": "§", "yen": "¥", "euro": "€",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓"
    ]

    static func decodeEntities(_ input: String) -> String {
        var result = input
        guard let regex = try? NSRegularExpression(pattern: #"&(#x?[0-9A-Fa-f]+|[a-zA-Z]+);"#) else {
            return result
        }
        let ns = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let token = ns.substring(with: match.range(at: 1))
            var replacement: String?
            if token.hasPrefix("#x") || token.hasPrefix("#X") {
                if let code = UInt32(token.dropFirst(2), radix: 16), let scalar = UnicodeScalar(code) {
                    replacement = String(scalar)
                }
            } else if token.hasPrefix("#") {
                if let code = UInt32(token.dropFirst()), let scalar = UnicodeScalar(code) {
                    replacement = String(scalar)
                }
            } else {
                replacement = entityMap[token.lowercased()]
            }
            if let replacement = replacement {
                result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }
        return result
    }

    static func stripTags(_ html: String) -> String {
        var text = removeScriptsAndStyles(html)
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</(p|div|tr|li|h[1-6]|section|article|header|footer)>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<td[^>]*>"#, with: "\t", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "\u{00a0}", with: " ")
        return text
    }

    static func visibleText(_ html: String) -> String {
        var text = stripTags(html)
        let lines = text.components(separatedBy: .newlines).map { line -> String in
            line.replacingOccurrences(of: #"[ \t\u{00a0}]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var cleaned: [String] = []
        var lastBlank = false
        for line in lines {
            if line.isEmpty {
                if !lastBlank { cleaned.append("") }
                lastBlank = true
            } else {
                cleaned.append(line)
                lastBlank = false
            }
        }
        return cleaned.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 提取页面正文：优先 article/main，否则 body；去掉导航、页脚、脚本等噪声。
    static func pageText(_ html: String) -> String {
        var source = removeScriptsAndStyles(html)
        source = source.replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
        source = source.replacingOccurrences(
            of: #"(?is)<(noscript|iframe|svg|form)\b[^>]*>.*?</\1\s*>"#,
            with: "",
            options: .regularExpression
        )

        let preferred = blockContents(tag: "article", in: source) + blockContents(tag: "main", in: source)
        let selected: String
        if let best = preferred.max(by: { visibleText($0).count < visibleText($1).count }),
           visibleText(best).count >= 30 {
            selected = best
        } else if let body = blockContents(tag: "body", in: source).first {
            selected = body
        } else {
            selected = source
        }

        let cleaned = selected.replacingOccurrences(
            of: #"(?is)<(nav|header|footer|aside)\b[^>]*>.*?</\1\s*>"#,
            with: "\n",
            options: .regularExpression
        )
        return trimTrailingNoise(visibleText(cleaned))
    }

    /// 去掉正文尾部常见的评论区、推荐列表等噪声；只在切分点足够靠后且保留内容足够长时生效。
    static func trimTrailingNoise(_ text: String) -> String {
        let markers = ["发表评论", "网友评论", "热门评论", "全部评论", "最新评论", "评论区", "畅言一下",
                       "文明上网理性发言", "相关阅读", "相关推荐", "热门推荐", "精彩推荐", "延伸阅读",
                       "猜你喜欢", "更多精彩内容", "相关新闻", "热点推荐", "网友跟帖", "我要评论", "换一批"]
        let lines = text.components(separatedBy: "\n")
        guard text.count >= 120, lines.count >= 3 else { return text }
        for (index, line) in lines.enumerated() {
            let value = line.trimmed
            guard !value.isEmpty, value.count <= 20 else { continue }
            guard markers.contains(where: { value == $0 || value.hasPrefix($0) }) else { continue }
            let prefixLength = lines[0...index].joined(separator: "\n").count
            guard prefixLength >= max(120, text.count / 5) else { continue }
            return lines[0..<index].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func blockContents(tag: String, in html: String) -> [String] {
        let pattern = "(?is)<\(tag)\\b[^>]*>(.*?)</\(tag)\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    static func title(_ html: String) -> String? {
        let pattern = #"<title[^>]*>([\s\S]*?)</title>"#
        guard let raw = firstCapture(pattern: pattern, in: html, options: [.caseInsensitive]) else { return nil }
        let value = stripTags(raw).trimmed
        return value.isEmpty ? nil : value
    }

    static func links(_ html: String) -> [HTMLLink] {
        let pattern = #"<a\b([^>]*)>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        var result: [HTMLLink] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges >= 3 else { continue }
            let attrs = ns.substring(with: match.range(at: 1))
            let inner = ns.substring(with: match.range(at: 2))
            guard let href = linkTarget(attrs) else { continue }
            let text = stripTags(inner).trimmed
            let aria = attribute("aria-label", in: attrs) ?? ""
            let title = attribute("title", in: attrs) ?? ""
            result.append(HTMLLink(href: href, text: text, ariaLabel: aria, title: title))
        }
        return result
    }

    /// 取链接目标：优先 href；部分站点用 onclick/tagname 承载地址（JS 分页）。
    private static func linkTarget(_ attrs: String) -> String? {
        if let href = attribute("href", in: attrs), !href.isEmpty,
           !href.lowercased().hasPrefix("javascript:") {
            return href
        }
        if let tagname = attribute("tagname", in: attrs), !tagname.isEmpty {
            return tagname
        }
        guard let onclick = attribute("onclick", in: attrs) else { return nil }
        let pattern = #"['"]([^'"]+\.html?[^'"]*)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: onclick, range: NSRange(onclick.startIndex..., in: onclick)),
              let range = Range(match.range(at: 1), in: onclick) else { return nil }
        return String(onclick[range])
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for i in 1..<match.numberOfRanges {
            if match.range(at: i).location != NSNotFound {
                return decodeEntities(ns.substring(with: match.range(at: i)))
            }
        }
        return nil
    }

    static func baseHref(_ html: String) -> String? {
        let pattern = #"<base\b[^>]*>"#
        guard let tag = firstCapture(pattern: pattern, in: html, options: [.caseInsensitive]) else { return nil }
        return attribute("href", in: tag)
    }

    static func firstCapture(pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    static func allCaptures(pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
            return ns.substring(with: match.range(at: 1))
        }
    }

    private static func removeScriptsAndStyles(_ html: String) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "template"] {
            let pattern = "(?is)<" + tag + #"[^>]*>[\s\S]*?</"# + tag + ">"
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text
    }

    /// 生成用于模型定位的压缩 DOM 骨架：保留标签层级、id/class 与每块文本摘要。
    static func outline(_ html: String, maxChars: Int = 10000) -> String {
        var source = removeScriptsAndStyles(html)
        source = source.replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
        source = source.replacingOccurrences(of: #"(?is)<head\b[^>]*>[\s\S]*?</head\s*>"#, with: "", options: .regularExpression)
        source = source.replacingOccurrences(of: #"(?is)<(svg|iframe|form)\b[^>]*>[\s\S]*?</\1\s*>"#, with: "", options: .regularExpression)

        let pattern = #"<([a-zA-Z][a-zA-Z0-9]*)([^>]*)>"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = source as NSString
            var edits: [(NSRange, String)] = []
            regex.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 3 else { return }
                let tag = ns.substring(with: match.range(at: 1)).lowercased()
                let attrs = ns.substring(with: match.range(at: 2))
                var label = "<" + tag
                if let id = attribute("id", in: attrs)?.trimmed, !id.isEmpty {
                    label += "#" + id
                }
                if let classes = attribute("class", in: attrs)?.trimmed, !classes.isEmpty {
                    let names = classes.split(whereSeparator: { $0.isWhitespace }).prefix(3)
                    if !names.isEmpty { label += "." + names.joined(separator: ".") }
                }
                label += ">"
                edits.append((match.range, label))
            }
            for (range, text) in edits.reversed() {
                source = (source as NSString).replacingCharacters(in: range, with: text)
            }
        }

        source = source.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        source = source.replacingOccurrences(of: #">\s+<"#, with: "><", options: .regularExpression)
        // 每块文本只保留前 120 字，避免把全文发给模型。
        source = source.replacingOccurrences(of: #">([^<]{120})[^<]*<"#, with: ">$1…<", options: .regularExpression)
        if source.count > maxChars {
            return String(source.prefix(maxChars)) + "…"
        }
        return source
    }

    /// 常见的站点导航/模板用语，用于判断正文是否夹带噪声。
    static let navigationWords = [
        "首页", "机构设置", "新闻动态", "政务公开", "政务服务", "互动交流", "专题专栏",
        "智能问答", "网站地图", "联系我们", "English", "繁體版", "无障碍", "用户空间",
        "登录", "注册", "当前位置", "视窗", "loading"
    ]

    static func navigationWordCount(_ text: String) -> Int {
        navigationWords.filter { text.contains($0) }.count
    }

    /// 判断默认规则提取的正文是否明显夹带导航/模板噪声；仅用于决定是否请模型定位。
    static func contentQuality(_ text: String) -> (poor: Bool, reason: String) {
        let value = text.trimmed
        if value.count < 200 {
            return (true, "正文仅 \(value.count) 字")
        }
        let hits = navigationWordCount(value)
        let lines = value.components(separatedBy: "\n").map { $0.trimmed }.filter { !$0.isEmpty }
        let shortLines = lines.filter { $0.count <= 4 }.count
        let shortRatio = lines.isEmpty ? 0 : Double(shortLines) / Double(lines.count)
        if hits >= 4 {
            return (true, "页面导航词 \(hits) 个")
        }
        if lines.count >= 30 && shortRatio > 0.5 {
            return (true, "短行占比 \(Int(shortRatio * 100))%")
        }
        // 正文被整页导航包裹时，开头会出现大量极短行（频道名、栏目名）。
        let head = Array(lines.prefix(12))
        let headShort = head.filter { $0.count <= 6 }.count
        if lines.count >= 12 && headShort >= 6 {
            return (true, "开头短行 \(headShort) 个")
        }
        return (false, "")
    }
}
