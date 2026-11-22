import Foundation

struct FeishuTarget: Hashable {
    let appId: String
    let appToken: String
    let tableId: String
}

struct FeishuError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class FeishuClient {
    private let appId: String
    private let appSecret: String
    private let appToken: String
    private let tableId: String
    private let http: HTTPClient
    private let log: LogStore
    private var tenantToken: String?
    private var validatedLevel = 0

    init(appId: String, appSecret: String, appToken: String, tableId: String, http: HTTPClient, log: LogStore) {
        self.appId = appId
        self.appSecret = appSecret
        self.appToken = appToken
        self.tableId = tableId
        self.http = http
        self.log = log
    }

    private static let base = "https://open.feishu.cn/open-apis"

    func validateFields(requiresPageText: Bool = false) async throws {
        let requiredLevel = requiresPageText ? 2 : 1
        if validatedLevel >= requiredLevel { return }
        let token = try await tokenValue()
        let url = URL(string: "\(FeishuClient.base)/bitable/v1/apps/\(appToken)/tables/\(tableId)/fields?page_size=100")!
        let result = try await requestWithRateLimit(url: url, method: "GET", body: nil, token: token)
        let json = try parse(result)
        if let code = json["code"] as? Int, code != 0 {
            throw FeishuError(message: "飞书接口返回错误：\(json["msg"] as? String ?? "代码 \(code)")")
        }
        guard let data = json["data"] as? [String: Any], let items = data["items"] as? [[String: Any]] else {
            throw FeishuError(message: "飞书数据表字段读取失败")
        }
        var fields: [String: Int] = [:]
        for item in items {
            if let name = item["field_name"] as? String, let type = item["type"] as? Int {
                fields[name] = type
            }
        }
        var expected: [(String, Int)] = [
            ("分类名称", 1), ("页面标题", 1), ("来源页面地址", 15), ("附件名称", 1),
            ("附件原始地址", 15), ("附件识别内容", 1), ("飞书附件链接", 15), ("采集时间", 5)
        ]
        if requiresPageText {
            expected.append(("记录类型", 1))
            expected.append(("页面正文", 1))
        }
        for (name, type) in expected {
            guard let actual = fields[name] else {
                throw FeishuError(message: "飞书数据表字段缺失：\(name)，请按说明书创建")
            }
            if actual != type {
                throw FeishuError(message: "飞书数据表字段类型不符：\(name)，请按说明书调整")
            }
        }
        validatedLevel = max(validatedLevel, requiredLevel)
    }

    func createRecord(record: CollectedRecord, uploadAttachment: Bool, fileURL: URL?, md5: String) async throws {
        if record.recordType == .pageText {
            try await validateFields(requiresPageText: true)
            let token = try await tokenValue()
            let linkText = record.pageTitle.isEmpty ? record.pageURL : record.pageTitle
            var fields: [String: Any] = [
                "分类名称": record.categoryName,
                "页面标题": record.pageTitle,
                "来源页面地址": ["link": record.pageURL, "text": linkText],
                "记录类型": "正文",
                "页面正文": truncate(record.pageText)
            ]
            fields["采集时间"] = Int(Date().timeIntervalSince1970 * 1000)
            try await create(fields: fields, token: token)
            return
        }

        try await validateFields(requiresPageText: false)
        let token = try await tokenValue()

        var attachmentLink = ""
        if uploadAttachment, let fileURL = fileURL {
            do {
                if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64, size > 20 * 1024 * 1024 {
                    log.info("文件超过飞书上传上限，已跳过上传", category: record.categoryName)
                } else {
                    attachmentLink = try await upload(fileURL: fileURL, fileName: record.fileName, token: token)
                }
            } catch {
                log.info("飞书附件上传失败：\(error.localizedDescription)，附件链接留空", category: record.categoryName)
            }
        }

        let content = truncate(record.content)
        var fields: [String: Any] = [
            "分类名称": record.categoryName,
            "页面标题": record.pageTitle,
            "来源页面地址": ["link": record.pageURL, "text": record.pageTitle],
            "附件名称": record.fileName,
            "附件原始地址": ["link": record.attachmentURL, "text": record.fileName],
            "附件识别内容": content
        ]
        if !attachmentLink.isEmpty {
            fields["飞书附件链接"] = ["link": attachmentLink, "text": "飞书附件"]
        }
        let milliseconds = Int(Date().timeIntervalSince1970 * 1000)
        fields["采集时间"] = milliseconds

        try await create(fields: fields, token: token)
    }

    private func create(fields: [String: Any], token: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["records": [["fields": fields]]])
        let url = URL(string: "\(FeishuClient.base)/bitable/v1/apps/\(appToken)/tables/\(tableId)/records/batch_create")!
        let result = try await requestWithRateLimit(url: url, method: "POST", body: body, token: token)
        let json = try parse(result)
        if let code = json["code"] as? Int, code != 0 {
            throw FeishuError(message: "飞书写入失败：\(json["msg"] as? String ?? "代码 \(code)")")
        }
    }

    private func upload(fileURL: URL, fileName: String, token: String) async throws -> String {
        guard let fileData = try? Data(contentsOf: fileURL) else {
            throw FeishuError(message: "附件读取失败")
        }
        let boundary = "----WebAttachBoundary" + UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(text.data(using: .utf8)!) }
        let pairs = [
            ("parent_type", "bitable_file"),
            ("parent_node", appToken),
            ("file_name", fileName)
        ]
        for (name, value) in pairs {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append(value)
            append("\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        let url = URL(string: "\(FeishuClient.base)/drive/v1/medias/upload_all")!
        let result = try await requestWithRateLimit(url: url, method: "MULTIPART", body: body, token: token, boundary: boundary)
        let json = try parse(result)
        if let code = json["code"] as? Int, code != 0 {
            throw FeishuError(message: "飞书附件上传失败：\(json["msg"] as? String ?? "代码 \(code)")")
        }
        guard let data = json["data"] as? [String: Any], let fileToken = data["file_token"] as? String else {
            throw FeishuError(message: "飞书附件上传未返回文件标识")
        }
        return "https://open.feishu.cn/open-apis/drive/v1/medias/\(fileToken)/download"
    }

    private func tokenValue() async throws -> String {
        if let tenantToken = tenantToken { return tenantToken }
        let url = URL(string: "\(FeishuClient.base)/auth/v3/tenant_access_token/internal")!
        let body = try JSONSerialization.data(withJSONObject: ["app_id": appId, "app_secret": appSecret])
        let result = try await requestWithRateLimit(url: url, method: "POST", body: body, token: nil)
        let json = try parse(result)
        guard let token = json["tenant_access_token"] as? String, !token.isEmpty else {
            throw FeishuError(message: "飞书应用凭证无效：\(json["msg"] as? String ?? "未返回访问令牌")")
        }
        tenantToken = token
        return token
    }

    private func requestWithRateLimit(url: URL, method: String, body: Data?, token: String?, boundary: String? = nil) async throws -> HTTPResult {
        var lastError: Error?
        for attempt in 0...3 {
            var headers: [String: String] = [:]
            if let token = token { headers["Authorization"] = "Bearer \(token)" }
            do {
                let result: HTTPResult
                switch method {
                case "GET":
                    result = try await http.get(url, extraHeaders: headers)
                case "MULTIPART":
                    result = try await http.postMultipart(url, body: body ?? Data(), boundary: boundary ?? "", extraHeaders: headers)
                default:
                    result = try await http.postJSON(url, body: body ?? Data(), extraHeaders: headers)
                }
                let json = (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any]
                let code = json?["code"] as? Int ?? 0
                let limited = result.status == 429 || code == 1254290 || code == 1254291
                if limited, attempt < 3 {
                    log.info("飞书接口访问过于频繁，已自动等待重试")
                    let delay = [2, 4, 8][attempt]
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                    continue
                }
                if result.status >= 500, attempt < 3 {
                    let delay = [2, 4, 8][attempt]
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                    continue
                }
                return result
            } catch {
                lastError = error
                if attempt < 3 {
                    let delay = [2, 4, 8][attempt]
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                    continue
                }
                throw error
            }
        }
        throw lastError ?? FeishuError(message: "飞书接口访问失败")
    }

    private func parse(_ result: HTTPResult) throws -> [String: Any] {
        guard let json = (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any] else {
            throw FeishuError(message: "飞书接口返回内容无法解析（HTTP \(result.status)）")
        }
        return json
    }

    private func truncate(_ text: String) -> String {
        if text.count <= 3000 { return text }
        return String(text.prefix(3000)) + "（内容过长已截断）"
    }
}
