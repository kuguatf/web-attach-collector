import Foundation
import AppKit
import PDFKit
import Vision
import ImageIO

struct RecognitionResult {
    var text: String
    var note: String?
}

enum RecognitionError: LocalizedError {
    case cannotOpen
    case pdfFailed(String)
    case ocrFailed(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen: return "无法打开附件文件"
        case .pdfFailed(let reason): return "PDF 解析失败：\(reason)"
        case .ocrFailed(let reason): return "文字识别失败：\(reason)"
        case .parseFailed(let reason): return "文档解析失败：\(reason)"
        }
    }
}

enum TextQuality {
    private static let uncommonSymbols: Set<Character> = Set("!\"#$%&'()*+<=>@[\\]^_{|}~")
    private static let privateUse: ClosedRange<UInt32> = 0xE000...0xF8FF

    /// R-M3-10 可读性校验：满足任一条件即判为不可读。
    static func isReadable(_ text: String) -> Bool {
        let chars = Array(text)
        let nonSpace = chars.filter { !$0.isWhitespace }
        if nonSpace.count < 20 { return false }
        let symbolCount = nonSpace.filter { uncommonSymbols.contains($0) }.count
        if Double(symbolCount) / Double(nonSpace.count) >= 0.30 { return false }

        let hanzi = chars.filter { isBasicHanzi($0) }
        if nonSpace.count >= 50 {
            let commonCount = hanzi.filter { commonHanzi.contains($0) }.count
            let coverage = hanzi.isEmpty ? 0 : Double(commonCount) / Double(hanzi.count)
            if coverage < 0.20 { return false }
        }

        let privateCount = chars.filter { ch in
            guard let scalar = ch.unicodeScalars.first else { return false }
            return privateUse.contains(scalar.value)
        }.count
        if Double(privateCount) / Double(nonSpace.count) >= 0.10 { return false }

        return true
    }

    static func isBasicHanzi(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        return scalar.value >= 0x4E00 && scalar.value <= 0x9FFF
    }

    /// 常用汉字集合（覆盖现代汉语高频用字），用于 R-M3-10 的覆盖率近似判定。
    static let commonHanzi: Set<Character> = Set(
        "的一是在不了有和人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定行学法所民得经十三之进着等部度家电力里如水化高自二理起小物现实加量都两体制机当使点从业本去把性好应开它合还因由其些然前外天政四日那社义事平形相全表间样与关各重新线内数正心反你明看原又么利比或但质气第向道命此变条只没结解问意建月公无系军很情者最立代想已通并提直题党程展五果料象员革位入常文总次品式活设及管特件长求老头基资边流路级少图山统接知较将组见计别她手角期根论运农指几九区强放决西被干做必战先回则任取据处理世车重便真务具万每目至达走积示议声报斗完类八离华名确才科张信马节话米整空元况今集温传土许步群广石记需段研界拉林律叫且究观越织装影算低持音众书布复容儿须际商非验连断深难近矿千周委素技备半办青省列习响约支般史感劳便团往酸历市克何除消构府称太准精值号率族维划选标写存候毛亲快效斯院查江型眼王按格养易置派层片始却专状育厂京识适属圆包火住调满县局照参红细引听该铁价严龙飞"
    ).union(Set(
        "电脑网络数据库文件附件下载采集识别技术项目管理控制系统信息服务用户界面操作设置参数分类规则关键词页面标题地址链接浏览器服务器请求响应内容文本图片扫描文档表格数据库配置保存加载日志任务运行停止继续开始结束成功失败错误提示确认取消默认全局继承独立覆盖增量全量清空删除复制新增上移下移选择目录路径标签笔记知识库表格多维云空间上传预览链接安全密钥接口频率限制重试超时时间间隔动态渲染深度遍历翻页页码模板起始最大包含排除穿透发现来源深度命中采集处理写入输出目标本地飞书奥布西迪安"
    ))

    static func clean(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        value = value.replacingOccurrences(of: #"[ \t\u{00a0}]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\n[ \t]*\n+"#, with: "\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class Recognizer {
    func recognize(fileURL: URL, ext: String, ocrEnabled: Bool) throws -> RecognitionResult {
        switch ext.lowercased() {
        case "pdf":
            return try recognizePDF(fileURL: fileURL, ocrEnabled: ocrEnabled)
        case "docx":
            return RecognitionResult(text: TextQuality.clean(try DOCXParser.parse(fileURL)), note: nil)
        case "doc":
            return recognizeLegacy(fileURL: fileURL)
        case "xlsx":
            return RecognitionResult(text: TextQuality.clean(try XLSXParser.parse(fileURL)), note: nil)
        case "xls":
            return recognizeLegacy(fileURL: fileURL)
        case "jpg", "jpeg", "png":
            if ocrEnabled {
                let text = try ocr(imageURL: fileURL)
                return RecognitionResult(text: TextQuality.clean(text), note: nil)
            }
            return RecognitionResult(text: "", note: "已关闭文字识别，图片识别内容留空")
        default:
            return RecognitionResult(text: "", note: "该格式暂不支持自动识别")
        }
    }

    private func recognizePDF(fileURL: URL, ocrEnabled: Bool) throws -> RecognitionResult {
        guard let document = PDFDocument(url: fileURL) else {
            throw RecognitionError.pdfFailed("文件无法打开或已损坏")
        }
        guard document.pageCount > 0 else {
            throw RecognitionError.pdfFailed("文件没有可用页面")
        }
        var pieces: [String] = []
        for index in 0..<document.pageCount {
            if let text = document.page(at: index)?.string, !text.trimmed.isEmpty {
                pieces.append(text)
            }
        }
        let layerText = pieces.joined(separator: "\n")
        if !layerText.trimmed.isEmpty && TextQuality.isReadable(layerText) {
            return RecognitionResult(text: TextQuality.clean(layerText), note: nil)
        }
        let reason = layerText.trimmed.isEmpty ? "文本层为空" : "文本层不可读"
        guard ocrEnabled else {
            return RecognitionResult(text: "", note: "\(reason)，已关闭文字识别，识别内容留空")
        }
        var ocrPieces: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            guard let image = renderPDFPage(page) else { continue }
            if let text = try? ocr(cgImage: image), !text.trimmed.isEmpty {
                ocrPieces.append(text)
            }
        }
        let text = TextQuality.clean(ocrPieces.joined(separator: "\n"))
        return RecognitionResult(text: text, note: "\(reason)，已转文字识别")
    }

    private func recognizeLegacy(fileURL: URL) -> RecognitionResult {
        let result = ProcessRunner.run("/usr/bin/textutil", ["-convert", "txt", "-stdout", fileURL.path])
        if result.status == 0, let text = String(data: result.output, encoding: .utf8), !text.trimmed.isEmpty {
            return RecognitionResult(text: TextQuality.clean(text), note: nil)
        }
        return RecognitionResult(text: "", note: "该格式暂不支持自动识别")
    }

    private func renderPDFPage(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale: CGFloat = 2.0
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    func ocr(imageURL: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RecognitionError.ocrFailed("图片无法读取")
        }
        return try ocr(cgImage: image)
    }

    func ocr(cgImage: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw RecognitionError.ocrFailed(error.localizedDescription)
        }
        guard let results = request.results else { return "" }
        return results.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

enum ProcessRunner {
    struct Result {
        let status: Int32
        let output: Data
        let errorText: String
    }

    static func run(_ executable: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            return Result(status: process.terminationStatus, output: data, errorText: String(data: errData, encoding: .utf8) ?? "")
        } catch {
            return Result(status: -1, output: Data(), errorText: error.localizedDescription)
        }
    }
}

enum DOCXParser {
    static func parse(_ fileURL: URL) throws -> String {
        let result = ProcessRunner.run("/usr/bin/unzip", ["-p", fileURL.path, "word/document.xml"])
        guard result.status == 0, !result.output.isEmpty else {
            throw RecognitionError.parseFailed("无法读取 docx 内容")
        }
        guard var xml = String(data: result.output, encoding: .utf8) else {
            throw RecognitionError.parseFailed("docx 内容编码异常")
        }
        xml = xml.replacingOccurrences(of: #"</w:p>"#, with: "\n", options: .regularExpression)
        xml = xml.replacingOccurrences(of: #"<w:tab[^>]*/>"#, with: "\t", options: .regularExpression)
        xml = xml.replacingOccurrences(of: #"<w:br[^>]*/>"#, with: "\n", options: .regularExpression)
        xml = xml.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return HTML.decodeEntities(xml)
    }
}

enum XLSXParser {
    static func parse(_ fileURL: URL) throws -> String {
        var shared: [String] = []
        let sharedResult = ProcessRunner.run("/usr/bin/unzip", ["-p", fileURL.path, "xl/sharedStrings.xml"])
        if sharedResult.status == 0, let xml = String(data: sharedResult.output, encoding: .utf8) {
            let items = HTML.allCaptures(pattern: #"<si>([\s\S]*?)</si>"#, in: xml, options: [.caseInsensitive])
            shared = items.map { item in
                let texts = HTML.allCaptures(pattern: #"<t[^>]*>([\s\S]*?)</t>"#, in: item, options: [.caseInsensitive])
                return HTML.decodeEntities(texts.joined())
            }
        }

        let listing = ProcessRunner.run("/usr/bin/unzip", ["-Z1", fileURL.path])
        guard listing.status == 0 else {
            throw RecognitionError.parseFailed("无法读取 xlsx 内容")
        }
        let names = (String(data: listing.output, encoding: .utf8) ?? "")
            .components(separatedBy: .newlines)
            .filter { $0.contains("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted()
        guard !names.isEmpty else {
            throw RecognitionError.parseFailed("xlsx 中没有工作表")
        }

        var sheets: [String] = []
        for name in names {
            let result = ProcessRunner.run("/usr/bin/unzip", ["-p", fileURL.path, name])
            guard result.status == 0, let xml = String(data: result.output, encoding: .utf8) else { continue }
            var rows: [String] = []
            let rowXMLs = HTML.allCaptures(pattern: #"<row[^>]*>([\s\S]*?)</row>"#, in: xml, options: [.caseInsensitive])
            for rowXML in rowXMLs {
                var cells: [String] = []
                for cell in HTML.allCaptures(pattern: #"<c([^>]*)>([\s\S]*?)</c>"#, in: rowXML, options: [.caseInsensitive]) {
                    _ = cell
                }
                let cellMatches = regexMatches(pattern: #"<c([^>]*)>([\s\S]*?)</c>"#, in: rowXML)
                for groups in cellMatches {
                    let attrs = groups[0]
                    let inner = groups[1]
                    let type = HTML.attribute("t", in: attrs) ?? ""
                    var value = ""
                    if type == "s" {
                        if let raw = HTML.firstCapture(pattern: #"<v>([\s\S]*?)</v>"#, in: inner),
                           let index = Int(raw.trimmed), index >= 0, index < shared.count {
                            value = shared[index]
                        }
                    } else if type == "inlineStr" {
                        let texts = HTML.allCaptures(pattern: #"<t[^>]*>([\s\S]*?)</t>"#, in: inner, options: [.caseInsensitive])
                        value = HTML.decodeEntities(texts.joined())
                    } else {
                        if let raw = HTML.firstCapture(pattern: #"<v>([\s\S]*?)</v>"#, in: inner) {
                            value = HTML.decodeEntities(raw)
                        } else {
                            let texts = HTML.allCaptures(pattern: #"<t[^>]*>([\s\S]*?)</t>"#, in: inner, options: [.caseInsensitive])
                            value = HTML.decodeEntities(texts.joined())
                        }
                    }
                    cells.append(value)
                }
                if cells.contains(where: { !$0.trimmed.isEmpty }) {
                    rows.append(cells.joined(separator: "\t"))
                }
            }
            sheets.append(rows.joined(separator: "\n"))
        }
        return sheets.joined(separator: "\n\n")
    }

    private static func regexMatches(pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            return [ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2))]
        }
    }
}
