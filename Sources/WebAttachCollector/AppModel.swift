import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var config: AppConfig {
        didSet {
            if !suppressDirty { hasUnsavedChanges = true }
        }
    }
    @Published var selectedCategoryID: UUID?
    @Published var running = false
    @Published var progress = RunProgress()
    @Published var schemes: [String] = []
    @Published var selectedScheme = "default"
    @Published var hasUnsavedChanges = false
    @Published var showLaunchdHelp = false

    // 采集方案（Site Plan）
    @Published var planEditing: SitePlan?
    @Published var planPreview: SitePlanPreview?
    @Published var planBusy = false
    @Published var planStatusText = ""
    @Published var planErrorText: String?
    @Published var planElapsed: Double = 0
    @Published var planUsedModel = false

    let log = LogStore()

    private var runTask: Task<Void, Never>?
    private var planTask: Task<Void, Never>?
    private var activeLock: RunLock?
    private var activeStopToken: StopToken?
    private var suppressDirty = false

    var currentConfigURL: URL {
        AppPaths.configDir.appendingPathComponent(selectedScheme + ".json")
    }

    init() {
        AppPaths.ensureDirectories()
        var loaded = AppModel.loadConfigFromDefault() ?? AppConfig()
        if loaded.stagingDir.trimmed.isEmpty {
            loaded.stagingDir = AppPaths.attachmentsDir.path
        }
        config = loaded
        selectedCategoryID = loaded.categories.first?.id
        refreshSchemes()
        if let first = schemes.first { selectedScheme = first }
        if selectedScheme != "default", let data = try? Data(contentsOf: currentConfigURL),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
            selectedCategoryID = decoded.categories.first?.id
        }
        suppressDirty = false
        hasUnsavedChanges = false
    }

    private static func loadConfigFromDefault() -> AppConfig? {
        guard let data = try? Data(contentsOf: AppPaths.defaultConfigFile),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else { return nil }
        return decoded
    }

    // MARK: - 绑定

    func binding<T>(_ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { self.config[keyPath: keyPath] = $0 }
        )
    }

    func categoryBinding<T>(_ keyPath: WritableKeyPath<CategoryConfig, T>) -> Binding<T>? {
        guard let id = selectedCategoryID else { return nil }
        return Binding(
            get: {
                guard let index = self.config.categories.firstIndex(where: { $0.id == id }) else {
                    return CategoryConfig()[keyPath: keyPath]
                }
                return self.config.categories[index][keyPath: keyPath]
            },
            set: { value in
                guard let index = self.config.categories.firstIndex(where: { $0.id == id }) else { return }
                self.config.categories[index][keyPath: keyPath] = value
            }
        )
    }

    var selectedCategory: CategoryConfig? {
        guard let id = selectedCategoryID else { return nil }
        return config.categories.first { $0.id == id }
    }

    func overrideDouble(_ keyPath: WritableKeyPath<OverrideConfig, Double?>, global: Double) -> Binding<Double> {
        Binding(
            get: { self.selectedCategory?.overrides[keyPath: keyPath] ?? global },
            set: { value in
                guard let index = self.selectedCategoryIndex() else { return }
                self.config.categories[index].overrides[keyPath: keyPath] = value
            }
        )
    }

    func overrideInt(_ keyPath: WritableKeyPath<OverrideConfig, Int?>, global: Int) -> Binding<Int> {
        Binding(
            get: { self.selectedCategory?.overrides[keyPath: keyPath] ?? global },
            set: { value in
                guard let index = self.selectedCategoryIndex() else { return }
                self.config.categories[index].overrides[keyPath: keyPath] = value
            }
        )
    }

    func overrideRule() -> Binding<IncrementalRule> {
        Binding(
            get: { self.selectedCategory?.overrides.incrementalRule ?? self.config.incrementalRule },
            set: { value in
                guard let index = self.selectedCategoryIndex() else { return }
                self.config.categories[index].overrides.incrementalRule = value
            }
        )
    }

    func overrideDynamic() -> Binding<Bool> {
        Binding(
            get: { self.selectedCategory?.overrides.dynamicRendering ?? self.config.dynamicRendering },
            set: { value in
                guard let index = self.selectedCategoryIndex() else { return }
                self.config.categories[index].overrides.dynamicRendering = value
            }
        )
    }

    private func selectedCategoryIndex() -> Int? {
        guard let id = selectedCategoryID else { return nil }
        return config.categories.firstIndex { $0.id == id }
    }

    // MARK: - 密钥

    private func currentLLMKey() -> String? {
        let value = config.smart.apiKey.trimmed
        return value.isEmpty ? nil : value
    }

    // MARK: - 配置存取

    func refreshSchemes() {
        let fm = FileManager.default
        var names = ["default"]
        if let files = try? fm.contentsOfDirectory(at: AppPaths.configDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension.lowercased() == "json" {
                let name = file.deletingPathExtension().lastPathComponent
                if name != "default" { names.append(name) }
            }
        }
        schemes = names.sorted()
    }

    private func writeConfig(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func saveConfig() {
        do {
            try FileManager.default.createDirectory(at: AppPaths.configDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(config)
            try writeConfig(data, to: AppPaths.defaultConfigFile)
            if selectedScheme != "default" {
                try writeConfig(data, to: currentConfigURL)
            }
            suppressDirty = true
            hasUnsavedChanges = false
            suppressDirty = false
            refreshSchemes()
            log.info("配置已保存")
        } catch {
            alert("配置保存失败", info: error.localizedDescription)
        }
    }

    func loadConfigFromDisk() {
        let panel = NSOpenPanel()
        panel.title = "加载配置"
        panel.directoryURL = AppPaths.configDir
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !hasUnsavedChanges || confirm("当前配置有未保存改动，加载后将丢失，确认继续？") else { return }
        loadConfig(url: url, scheme: url.deletingPathExtension().lastPathComponent)
        log.info("已加载配置：\(url.lastPathComponent)")
    }

    private func loadConfig(url: URL, scheme: String) {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            alert("配置加载失败", info: "文件格式不正确或已损坏")
            return
        }
        suppressDirty = true
        config = decoded
        selectedCategoryID = decoded.categories.first?.id
        selectedScheme = scheme
        suppressDirty = false
        hasUnsavedChanges = false
    }

    func saveAsScheme() {
        let panel = NSSavePanel()
        panel.title = "另存为配置"
        panel.directoryURL = AppPaths.configDir
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "配置-\(TimeFormat.string().prefix(10)).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(config)
            try writeConfig(data, to: url)
            selectedScheme = url.deletingPathExtension().lastPathComponent
            refreshSchemes()
            hasUnsavedChanges = false
            log.info("配置已另存为：\(url.lastPathComponent)")
        } catch {
            alert("配置另存失败", info: error.localizedDescription)
        }
    }

    func switchScheme(_ name: String) {
        guard name != selectedScheme else { return }
        guard !hasUnsavedChanges || confirm("当前配置有未保存改动，切换方案后将丢失，确认继续？") else {
            return
        }
        if name == "default" {
            if let loaded = AppModel.loadConfigFromDefault() {
                suppressDirty = true
                config = loaded
                selectedCategoryID = loaded.categories.first?.id
                suppressDirty = false
                hasUnsavedChanges = false
            }
            selectedScheme = "default"
        } else {
            let url = AppPaths.configDir.appendingPathComponent(name + ".json")
            loadConfig(url: url, scheme: name)
        }
    }

    // MARK: - 分类

    func addCategory() {
        var name = "新分类"
        var index = 2
        while config.categories.contains(where: { $0.name == name }) {
            name = "新分类\(index)"
            index += 1
        }
        let category = CategoryConfig(name: name)
        config.categories.append(category)
        selectedCategoryID = category.id
    }

    func duplicateCategory() {
        guard let index = selectedCategoryIndex() else { return }
        var copy = config.categories[index]
        copy.id = UUID()
        copy.enabled = false
        var name = copy.name + "-副本"
        var counter = 2
        while config.categories.contains(where: { $0.name == name }) {
            name = copy.name + "-副本\(counter)"
            counter += 1
        }
        copy.name = name
        config.categories.insert(copy, at: index + 1)
        selectedCategoryID = copy.id
    }

    func deleteCategory() {
        guard let index = selectedCategoryIndex() else { return }
        let name = config.categories[index].name
        guard confirm("删除分类「\(name)」？该操作不可撤销。") else { return }
        config.categories.remove(at: index)
        selectedCategoryID = config.categories.first?.id
    }

    func moveCategory(up: Bool) {
        guard let index = selectedCategoryIndex() else { return }
        let target = up ? index - 1 : index + 1
        guard target >= 0, target < config.categories.count else { return }
        config.categories.swapAt(index, target)
    }

    // MARK: - 采集方案

    func planBinding<T>(_ keyPath: WritableKeyPath<SitePlan, T>) -> Binding<T>? {
        guard planEditing != nil else { return nil }
        return Binding(
            get: { self.planEditing?[keyPath: keyPath] ?? SitePlan()[keyPath: keyPath] },
            set: { self.planEditing?[keyPath: keyPath] = $0 }
        )
    }

    /// 选择器数组在界面用英文逗号分隔编辑。
    func planListBinding(_ keyPath: WritableKeyPath<SitePlan, [String]>) -> Binding<String>? {
        guard let base = planBinding(keyPath) else { return nil }
        return Binding(
            get: { base.wrappedValue.joined(separator: ", ") },
            set: { text in
                let values = text.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
                    .map { $0.trimmed }
                    .filter { !$0.isEmpty }
                base.wrappedValue = values
            }
        )
    }

    func reloadPlanForSelection() {
        planTask?.cancel()
        planTask = nil
        planBusy = false
        planPreview = nil
        planErrorText = nil
        planElapsed = 0
        planUsedModel = false
        guard let category = selectedCategory,
              let text = category.pageURLs.first(where: { !$0.trimmed.isEmpty }),
              let url = URL(string: text),
              let stored = SitePlanStore().stored(for: url),
              stored.meta.confirmed else {
            planEditing = nil
            planStatusText = ""
            return
        }
        planEditing = stored
        planStatusText = "已保存方案（\(stored.meta.createdAt)）"
    }

    func generateSitePlan() {
        guard !planBusy, !running, let category = selectedCategory else { return }
        let entryText = category.pageURLs.first(where: { !$0.trimmed.isEmpty }) ?? config.targetURL.trimmed
        guard !entryText.isEmpty, let entry = URL(string: entryText) else {
            planErrorText = "请先填写分类的入口网址"
            return
        }
        planBusy = true
        planErrorText = nil
        planPreview = nil
        planElapsed = 0
        planUsedModel = false
        planStatusText = "正在分析页面结构…"

        let configSnapshot = config
        let dynamic = EffectiveParameters(global: config, category: category).dynamicRendering
        let key = currentLLMKey()
        let logStore = log
        planTask = Task { [weak self] in
            let loader = PageLoader(config: configSnapshot, log: logStore, limiter: RequestLimiter())
            let generator = SitePlanGenerator(smart: configSnapshot.smart, apiKey: key, log: logStore, useDynamic: dynamic)
            defer {
                loader.shutdown()
                generator.close()
            }
            do {
                let page = try await loader.load(entry, useDynamic: dynamic, keepHTML: true)
                let result = await generator.generate(entry: entry, entryPage: page, loader: loader)
                guard !Task.isCancelled else { return }
                self?.planBusy = false
                self?.planEditing = result.plan
                self?.planPreview = result.preview
                self?.planElapsed = result.preview.elapsed
                self?.planUsedModel = result.preview.usedModel
                if let error = result.error {
                    self?.planErrorText = error
                    self?.planStatusText = "未生成可靠方案"
                } else {
                    self?.planErrorText = nil
                    let validation = result.validation
                    self?.planStatusText = validation.passed
                        ? "已生成方案：列表 \(validation.listCount) 条，请核对前 3 条与正文预览后保存"
                        : "方案部分字段未命中，可调整选择器或重新分析"
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.planBusy = false
                self?.planErrorText = "生成失败：\(error.localizedDescription)"
                self?.planStatusText = "生成失败"
            }
        }
    }

    func savePlanAndStart() {
        guard var plan = planEditing, let category = selectedCategory, !running else { return }
        let entryText = category.pageURLs.first(where: { !$0.trimmed.isEmpty }) ?? config.targetURL.trimmed
        guard !entryText.isEmpty else {
            alert("无法保存方案", info: "请先填写入口网址")
            return
        }
        if let index = selectedCategoryIndex(), config.categories[index].pageURLs.isEmpty {
            config.categories[index].pagesText = entryText
        }
        plan.meta.confirmed = true
        plan.meta.createdAt = TimeFormat.string()
        plan.meta.promptVersion = SitePlanStore.promptVersion
        if planPreview?.usedModel == true {
            plan.meta.model = config.smart.model
        }
        SitePlanStore().save(plan)
        planEditing = plan
        log.info("采集方案：已保存并确认（\(plan.host)\(plan.pathPattern)，列表 \(plan.list.item)）")
        start(forceFull: false)
    }

    func deleteSitePlan() {
        guard let category = selectedCategory,
              let text = category.pageURLs.first(where: { !$0.trimmed.isEmpty }),
              let url = URL(string: text) else { return }
        SitePlanStore().remove(for: url)
        planEditing = nil
        planPreview = nil
        planErrorText = nil
        planElapsed = 0
        planStatusText = "已清除站点方案，将回退默认规则"
        log.info("采集方案：已清除（\(url.absoluteString)）")
    }

    // MARK: - 运行

    func start(forceFull: Bool) {
        guard !running else { return }
        let key = currentLLMKey()
        if let error = ConfigValidator.firstError(config, llmKey: key) {
            alert("无法开始采集", info: error)
            return
        }
        for category in ConfigValidator.unboundCategories(config) {
            guard confirm("分类「\(category.name)」未绑定任何输出目标，确认继续？") else { return }
        }
        let hasInherit = config.categories.contains { $0.enabled && $0.outputMode == .inherit }
        if hasInherit && !config.globalOutputs.anyEnabled {
            guard confirm("全局输出目标未绑定任何输出，继承分类将只采集不输出，确认继续？") else { return }
        }
        saveConfig()
        guard let lock = RunLock.acquire(url: AppPaths.lockFile) else {
            alert("无法开始采集", info: "已有采集任务正在运行，请稍后再试")
            return
        }
        activeLock = lock
        let token = StopToken()
        activeStopToken = token
        running = true
        progress = RunProgress(status: "采集中")
        log.info("开始采集" + (forceFull ? "（强制全量）" : ""))
        let configSnapshot = config
        let runKey = key
        let logStore = log
        runTask = Task { [weak self] in
            let engine = CollectionEngine(
                config: configSnapshot,
                log: logStore,
                forceFull: forceFull,
                stop: token,
                llmKey: runKey,
                onProgress: { progress in
                    DispatchQueue.main.async {
                        self?.progress = progress
                    }
                }
            )
            let outcome = await engine.run()
            await MainActor.run {
                self?.finishRun(outcome)
            }
        }
    }

    private func finishRun(_ outcome: RunOutcome) {
        running = false
        activeLock?.release()
        activeLock = nil
        activeStopToken = nil
        runTask = nil
        progress.status = outcome.exitCode == 0 ? "已完成" : "出错"
        notify(title: outcome.exitCode == 0 ? "采集完成" : "采集出错", body: "详细结果请查看运行日志")
        let alert = NSAlert()
        alert.messageText = outcome.exitCode == 0 ? "采集完成" : "采集结束（有失败项）"
        alert.informativeText = outcome.summary
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func stopRun() {
        activeStopToken?.stop()
        progress.status = "正在停止…"
        log.info("用户请求停止采集")
    }

    func clearLogs() {
        log.clear()
    }

    func clearIncremental() {
        let store = IncrementalStore(path: AppPaths.expand(config.incrementalPath))
        guard store.available else {
            alert("清空增量记录", info: "增量记录文件无法读取")
            return
        }
        defer { store.close() }

        let dialog = NSAlert()
        dialog.messageText = "清空增量记录"
        dialog.informativeText = "此操作不可撤销，清空后下次运行会重新处理相关附件。"
        dialog.addButton(withTitle: "全部清空")
        dialog.addButton(withTitle: "按分类清空")
        dialog.addButton(withTitle: "取消")
        let response = dialog.runModal()
        if response == .alertFirstButtonReturn {
            guard confirm("确认清空全部增量记录？") else { return }
            do {
                try store.clearAll()
                log.info("已清空全部增量记录")
            } catch {
                alert("清空失败", info: error.localizedDescription)
            }
        } else if response == .alertSecondButtonReturn {
            let names = config.categories.map { $0.name }
            guard !names.isEmpty else {
                alert("按分类清空", info: "当前没有分类")
                return
            }
            guard let selected = multiSelect(title: "选择要清空增量记录的分类", options: names) else { return }
            guard !selected.isEmpty else { return }
            guard confirm("确认清空所选 \(selected.count) 个分类的增量记录？") else { return }
            do {
                try store.clear(categories: selected)
                log.info("已清空分类增量记录：\(selected.joined(separator: "、"))")
            } catch {
                alert("清空失败", info: error.localizedDescription)
            }
        }
    }

    // MARK: - 面板与提示

    func pickFolder(title: String, current: String, completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: AppPaths.expand(current), isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }

    func pickDatabaseFile(current: String, completion: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.title = "选择本地数据库文件"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "采集结果.sqlite"
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: AppPaths.expand(current)).deletingLastPathComponent()
            panel.nameFieldStringValue = URL(fileURLWithPath: AppPaths.expand(current)).lastPathComponent
        }
        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }

    func alert(_ title: String, info: String = "") {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func confirm(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "确认")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func multiSelect(title: String, options: [String]) -> [String]? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "可多选，按住 Command 点击。"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        scroll.hasVerticalScroller = true
        let table = NSTableView()
        table.headerView = nil
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 300
        table.addTableColumn(column)
        table.allowsMultipleSelection = true
        let dataSource = CategorySelectionDataSource(items: options)
        table.dataSource = dataSource
        table.delegate = dataSource
        scroll.documentView = table
        alert.accessoryView = scroll

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return table.selectedRowIndexes.map { options[$0] }
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
    }
}

private final class CategorySelectionDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let items: [String]
    init(items: [String]) { self.items = items }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let view: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
            view = reused
        } else {
            view = NSTextField(labelWithString: "")
            view.identifier = identifier
        }
        view.stringValue = items[row]
        return view
    }
}
