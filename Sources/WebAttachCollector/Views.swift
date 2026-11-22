import SwiftUI
import AppKit

struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.6))
    }
}

struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 96, alignment: .trailing)
            content
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                SettingsPanel()
                GlobalOutputsPanel()
            }
            .frame(height: 196)

            CategoriesPanel()
                .frame(height: 350)

            SchemeBar()
            ActionBar()
            LogPanel()
                .frame(minHeight: 220)
            StatusBar()
        }
        .padding(10)
        .frame(minWidth: 1000, minHeight: 780, alignment: .topLeading)
        .sheet(isPresented: $model.showLaunchdHelp) {
            LaunchdHelpView()
                .environmentObject(model)
        }
    }
}

// MARK: - ① 采集设置

struct SettingsPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SectionBox(title: "① 采集设置") {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    FormRow(label: "采集目标地址") {
                        TextField("未使用分类时必填，例如 https://example.com/list", text: model.binding(\.targetURL))
                            .textFieldStyle(.roundedBorder)
                    }
                    FormRow(label: "请求标识") {
                        TextField("User-Agent", text: model.binding(\.userAgent))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                    FormRow(label: "附件暂存目录") {
                        HStack(spacing: 4) {
                            TextField("", text: model.binding(\.stagingDir))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                            Button("选择…") {
                                let binding = model.binding(\.stagingDir)
                                model.pickFolder(title: "选择附件暂存目录", current: binding.wrappedValue) { path in
                                    binding.wrappedValue = path
                                }
                            }
                        }
                    }
                    HStack(spacing: 12) {
                        FormRow(label: "请求间隔（秒）") {
                            TextField("", value: model.binding(\.requestInterval), format: .number.precision(.fractionLength(0...2)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                        }
                        FormRow(label: "超时（秒）") {
                            TextField("", value: model.binding(\.requestTimeout), format: .number.precision(.fractionLength(0...1)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                        }
                        FormRow(label: "最大附件数") {
                            TextField("", value: model.binding(\.maxAttachments), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                        }
                    }
                    HStack(spacing: 16) {
                        Toggle("启用动态页面渲染模式", isOn: model.binding(\.dynamicRendering))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                        Toggle("启用文字识别", isOn: model.binding(\.ocrEnabled))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                    }
                    Divider()
                    HStack {
                        Toggle("启用智能判定（默认关闭）", isOn: model.binding(\.smart.enabled))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12, weight: .medium))
                        Toggle("智能正文定位（按站点模板缓存）", isOn: model.binding(\.smart.locateContent))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        if model.config.smart.enabled {
                            Text("仅对规则无法唯一归属的附件生效")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    if model.config.smart.locateContent && !model.config.smart.enabled {
                        Text("默认规则提取的正文夹带导航等噪声时，才请模型给出正文选择器；同一站点模板只调用一次。")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if model.config.smart.enabled || model.config.smart.locateContent {
                        FormRow(label: "服务地址") {
                            TextField("兼容 OpenAI Chat Completions 的完整接口地址", text: model.binding(\.smart.endpoint))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }
                        FormRow(label: "模型名称") {
                            TextField("例如 qwen-plus", text: model.binding(\.smart.model))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }
                        FormRow(label: "API Key") {
                            SecureField("保存在应用配置中（明文）", text: model.binding(\.smart.apiKey))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }
                        HStack(spacing: 12) {
                            FormRow(label: "批量大小") {
                                TextField("", value: model.binding(\.smart.batchSize), format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 56)
                            }
                            FormRow(label: "最大调用") {
                                TextField("", value: model.binding(\.smart.maxCalls), format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 56)
                            }
                            FormRow(label: "最大字符") {
                                TextField("", value: model.binding(\.smart.maxInputChars), format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                            }
                            Button("清除智能缓存") {
                                SmartJudge.clearCache()
                                model.log.info("智能判定缓存已清除")
                            }
                            .font(.system(size: 11))
                            Button("清除正文定位缓存") {
                                ContentPlanStore.clear()
                                model.log.info("正文定位缓存已清除")
                            }
                            .font(.system(size: 11))
                        }
                    }
                }
                .padding(.trailing, 4)
            }
        }
    }
}

// MARK: - ② 全局输出目标

struct GlobalOutputsPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SectionBox(title: "② 全局输出目标") {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("启用增量采集", isOn: model.binding(\.incrementalEnabled))
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                            HStack {
                                Text("判定规则").font(.system(size: 12)).foregroundColor(.secondary)
                                Picker("", selection: model.binding(\.incrementalRule)) {
                                    ForEach(IncrementalRule.allCases, id: \.self) { rule in
                                        Text(rule.title).tag(rule)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 150)
                                Button("清空增量记录") { model.clearIncremental() }
                                    .disabled(model.running)
                            }
                        }
                        .padding(4)
                    } label: {
                        Text("增量采集").font(.system(size: 12, weight: .semibold))
                    }

                    OutputsEditor(outputs: $model.config.globalOutputs)
                }
                .padding(.trailing, 4)
            }
        }
    }
}

struct OutputsEditor: View {
    @Binding var outputs: OutputSet
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupBox {
                VStack(alignment: .leading, spacing: 5) {
                    Toggle("启用本地数据库", isOn: $outputs.database.enabled)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    HStack(spacing: 4) {
                        TextField("数据库文件路径", text: $outputs.database.path)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        Button("选择…") {
                            let binding = $outputs.database.path
                            model.pickDatabaseFile(current: binding.wrappedValue) { binding.wrappedValue = $0 }
                        }
                        .font(.system(size: 11))
                    }
                    .disabled(!outputs.database.enabled)
                }
                .padding(4)
            } label: {
                Text("本地数据库").font(.system(size: 12, weight: .semibold))
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 5) {
                    Toggle("启用飞书多维表格", isOn: $outputs.feishu.enabled)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        TextField("App ID", text: $outputs.feishu.appId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        SecureField("App Secret（保存在应用配置中）", text: $outputs.feishu.appSecret)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        TextField("App Token", text: $outputs.feishu.appToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        TextField("数据表 table_id", text: $outputs.feishu.tableId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        Toggle("上传附件到多维表格（≤20MB）", isOn: $outputs.feishu.uploadAttachment)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                    }
                    .disabled(!outputs.feishu.enabled)
                }
                .padding(4)
            } label: {
                Text("飞书多维表格").font(.system(size: 12, weight: .semibold))
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 5) {
                    Toggle("启用 Obsidian 知识库", isOn: $outputs.obsidian.enabled)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 4) {
                            TextField("知识库根目录", text: $outputs.obsidian.vaultPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                            Button("选择…") {
                                let binding = $outputs.obsidian.vaultPath
                                model.pickFolder(title: "选择 Obsidian 知识库根目录", current: binding.wrappedValue) { binding.wrappedValue = $0 }
                            }
                            .font(.system(size: 11))
                        }
                        HStack(spacing: 4) {
                            TextField("笔记子文件夹", text: $outputs.obsidian.notesFolder)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                            TextField("附件子文件夹", text: $outputs.obsidian.assetsFolder)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }
                        TextField("笔记标签（英文逗号分隔）", text: $outputs.obsidian.tags)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                    .disabled(!outputs.obsidian.enabled)
                }
                .padding(4)
            } label: {
                Text("Obsidian 知识库").font(.system(size: 12, weight: .semibold))
            }
        }
    }
}

// MARK: - ③ 分类采集

struct CategoriesPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SectionBox(title: "③ 分类采集（分类即分区，不同分类可写入不同落点）") {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(model.config.categories) { category in
                                CategoryRow(category: category)
                            }
                            if model.config.categories.isEmpty {
                                Text("暂无分类\n未使用分类时按单页面模式采集")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.top, 12)
                            }
                        }
                        .padding(4)
                    }
                    .frame(width: 228)
                    HStack(spacing: 4) {
                        Button("新增") { model.addCategory() }
                        Button("复制") { model.duplicateCategory() }
                        Button("删除") { model.deleteCategory() }
                        Button("上移") { model.moveCategory(up: true) }
                        Button("下移") { model.moveCategory(up: false) }
                    }
                    .font(.system(size: 11))
                    .padding(4)
                }
                Divider()
                if model.selectedCategory != nil {
                    CategoryDetail()
                } else {
                    VStack {
                        Spacer()
                        Text("请选择或新增一个分类")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct CategoryRow: View {
    @EnvironmentObject private var model: AppModel
    let category: CategoryConfig

    var body: some View {
        HStack(spacing: 4) {
            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 0) {
                Text(category.name.isEmpty ? "未命名分类" : category.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text("\(category.pageURLs.count) 个页面")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(model.selectedCategoryID == category.id ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectedCategoryID = category.id }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.config.categories.first { $0.id == category.id }?.enabled ?? false },
            set: { value in
                if let index = model.config.categories.firstIndex(where: { $0.id == category.id }) {
                    model.config.categories[index].enabled = value
                }
            }
        )
    }
}

struct CategoryDetail: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let nameBinding = model.categoryBinding(\.name) {
                    HStack(spacing: 8) {
                        FormRow(label: "分类名称") {
                            TextField("1–32 字符", text: nameBinding)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                        }
                        Toggle("启用", isOn: model.categoryBinding(\.enabled) ?? .constant(true))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                    }
                }

                if let pagesBinding = model.categoryBinding(\.pagesText) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("页面地址（每行一个入口网址，按顺序采集）")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        TextEditor(text: pagesBinding)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 58)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
                    }
                }

                if let modeBinding = model.categoryBinding(\.contentMode) {
                    FormRow(label: "采集内容") {
                        Picker("", selection: modeBinding) {
                            ForEach(ContentMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }

                if let keywordBinding = model.categoryBinding(\.attachmentKeywords) {
                    FormRow(label: "附件归入关键词") {
                        TextField("英文逗号分隔，命中任一即归属本分类；留空表示不过滤", text: keywordBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .disabled(model.selectedCategory?.contentMode == .pageText)
                    }
                }
                if model.selectedCategory?.contentMode == .pageText {
                    Text("仅正文模式：不下载附件；正文只采通过页面关键词/包含规则的发现页，无发现页时采入口页。")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                SitePlanPanel()

                HStack(spacing: 8) {
                    Text("输出目标模式").font(.system(size: 12)).foregroundColor(.secondary)
                    Picker("", selection: model.categoryBinding(\.outputMode) ?? .constant(.inherit)) {
                        ForEach(OutputMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }

                if model.selectedCategory?.outputMode == .custom,
                   let outputsBinding = model.categoryBinding(\.customOutputs) {
                    OutputsEditor(outputs: outputsBinding)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("覆盖全局参数", isOn: model.categoryBinding(\.overrideEnabled) ?? .constant(false))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                        if model.selectedCategory?.overrideEnabled == true {
                            HStack(spacing: 10) {
                                FormRow(label: "请求间隔") {
                                    TextField("", value: model.overrideDouble(\.interval, global: model.config.requestInterval), format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 50)
                                }
                                FormRow(label: "超时") {
                                    TextField("", value: model.overrideDouble(\.timeout, global: model.config.requestTimeout), format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 50)
                                }
                                FormRow(label: "最大附件") {
                                    TextField("", value: model.overrideInt(\.maxAttachments, global: model.config.maxAttachments), format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 55)
                                }
                            }
                            HStack(spacing: 10) {
                                Picker("增量规则", selection: model.overrideRule()) {
                                    ForEach(IncrementalRule.allCases, id: \.self) { rule in
                                        Text(rule.title).tag(rule)
                                    }
                                }
                                .frame(width: 210)
                                Toggle("动态渲染", isOn: model.overrideDynamic())
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 12))
                            }
                        }
                    }
                    .padding(4)
                } label: {
                    Text("参数覆盖").font(.system(size: 12, weight: .semibold))
                }

                DiscoveryEditor()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .onAppear { model.reloadPlanForSelection() }
        .onChange(of: model.selectedCategoryID) { _ in model.reloadPlanForSelection() }
    }
}

// MARK: - 采集方案面板

struct SitePlanPanel: View {
    @EnvironmentObject private var model: AppModel

    private let attrOptions: [SiteFieldAttr] = [.href, .onclick, .tagname, .src, .text, .title, .datetime]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(model.planEditing == nil ? "生成采集方案" : "重新分析") {
                        model.generateSitePlan()
                    }
                    .disabled(model.planBusy || model.running)
                    if model.planBusy {
                        ProgressView().controlSize(.small)
                    }
                    if model.planElapsed > 0 {
                        Text(String(format: "耗时 %.1fs", model.planElapsed))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    if model.planUsedModel {
                        Text("模型：\(model.config.smart.model)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if model.planEditing != nil {
                        Button("清除方案") { model.deleteSitePlan() }
                            .font(.system(size: 11))
                            .disabled(model.planBusy || model.running)
                    }
                }

                if let error = model.planErrorText {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !model.planStatusText.isEmpty {
                    Text(model.planStatusText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.planEditing != nil {
                    editor
                    if let preview = model.planPreview {
                        previewView(preview)
                    }
                    HStack {
                        Text("保存后本站点以后直接执行方案，不再调用模型。")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("保存方案并开始采集") { model.savePlanAndStart() }
                            .disabled(model.running || model.planBusy)
                    }
                } else {
                    Text("填写页面地址后点击「生成采集方案」。方案只包含声明式选择器，不含脚本；首次必须预览确认。")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(4)
        } label: {
            Text("采集方案（可编辑）").font(.system(size: 12, weight: .semibold))
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let item = model.planBinding(\.list.item) {
            FormRow(label: "列表项") {
                TextField("例如 ul.list li", text: item)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        HStack(spacing: 8) {
            if let title = model.planBinding(\.list.fields.title.selector) {
                FormRow(label: "标题") {
                    TextField("a", text: title)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 130)
                }
            }
            if let date = model.planBinding(\.list.fields.date.selector) {
                FormRow(label: "日期") {
                    TextField("可空，如 .date", text: date)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 130)
                }
            }
        }
        HStack(spacing: 8) {
            if let url = model.planBinding(\.list.fields.url.selector) {
                FormRow(label: "链接") {
                    TextField("a", text: url)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 130)
                }
            }
            if let attr = model.planBinding(\.list.fields.url.attr) {
                Picker("", selection: attr) {
                    ForEach(attrOptions, id: \.self) { value in
                        Text(value.title).tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }
        }
        HStack(spacing: 8) {
            if let type = model.planBinding(\.paging.type) {
                Picker("翻页", selection: type) {
                    ForEach(SitePagingType.allCases, id: \.self) { value in
                        Text(value.title).tag(value)
                    }
                }
                .frame(width: 210)
            }
            if model.planEditing?.paging.type == .link {
                if let selector = model.planBinding(\.paging.selector) {
                    TextField("下一页元素，如 a[title='下一页']", text: selector)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
                if let from = model.planBinding(\.paging.urlFrom) {
                    Picker("", selection: from) {
                        ForEach(attrOptions, id: \.self) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }
            if let maxPages = model.planBinding(\.paging.maxPages) {
                FormRow(label: "最多") {
                    TextField("", value: maxPages, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 48)
                }
            }
        }
        if model.planEditing?.paging.type == .template,
           let template = model.planBinding(\.paging.template) {
            FormRow(label: "页码模板") {
                TextField("含 {page} 的地址", text: template)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        if model.planEditing?.paging.type == .param {
            HStack(spacing: 8) {
                if let base = model.planBinding(\.paging.param.base) {
                    FormRow(label: "参数地址") {
                        TextField("含查询串的基础地址", text: base)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                if let name = model.planBinding(\.paging.param.name) {
                    FormRow(label: "参数名") {
                        TextField("page", text: name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 90)
                    }
                }
            }
            HStack(spacing: 8) {
                if let start = model.planBinding(\.paging.param.start) {
                    FormRow(label: "起始页") {
                        TextField("", value: start, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                    }
                }
                if let end = model.planBinding(\.paging.param.end) {
                    FormRow(label: "结束页") {
                        TextField("", value: end, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                    }
                }
            }
        }
        if let content = model.planListBinding(\.detail.content) {
            FormRow(label: "正文选择器") {
                TextField("多个用英文逗号分隔，如 #content", text: content)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        if let exclude = model.planListBinding(\.detail.exclude) {
            FormRow(label: "正文排除") {
                TextField("多个用英文逗号分隔，如 .share, .comment", text: exclude)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        HStack(spacing: 8) {
            if let selector = model.planBinding(\.attachments.linkSelector) {
                FormRow(label: "附件链接") {
                    TextField("a[href]", text: selector)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 130)
                }
            }
            if let extensions = model.planListBinding(\.attachments.extensions) {
                FormRow(label: "附件类型") {
                    TextField("pdf, doc, docx, xls, xlsx, jpg, png", text: extensions)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
            }
        }
    }

    private func previewView(_ preview: SitePlanPreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 8) {
                Text("试运行预览（前 3 条）").font(.system(size: 11, weight: .semibold))
                Text("列表共 \(preview.listCount) 条").font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
            }
            if preview.items.isEmpty {
                Text(preview.message.isEmpty ? "暂无预览数据" : preview.message)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text("#").font(.system(size: 10)).frame(width: 14, alignment: .trailing)
                    Text("标题").font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading)
                    Text("日期").font(.system(size: 10)).frame(width: 78, alignment: .leading)
                    Text("附件").font(.system(size: 10)).frame(width: 110, alignment: .leading)
                }
                .foregroundColor(.secondary)
                ForEach(preview.items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(item.index)")
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 14, alignment: .trailing)
                        Text(item.title.isEmpty ? "（标题为空）" : item.title)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(item.date)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .frame(width: 78, alignment: .leading)
                        Text(item.attachment)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(width: 110, alignment: .leading)
                    }
                }
            }
            if !preview.contentPreview.isEmpty {
                Text("正文预览：\(preview.contentPreview)\(preview.contentChars > 200 ? "…" : "")")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct DiscoveryEditor: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("页面发现").font(.system(size: 12)).foregroundColor(.secondary)
                    Picker("", selection: model.categoryBinding(\.discovery.mode) ?? .constant(.entry)) {
                        ForEach(DiscoveryMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    if model.selectedCategory?.discovery.mode != .entry {
                        FormRow(label: "最大深度") {
                            TextField("", value: model.categoryBinding(\.discovery.maxDepth) ?? .constant(2), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 45)
                        }
                        FormRow(label: "发现页数") {
                            TextField("", value: model.categoryBinding(\.discovery.maxPages) ?? .constant(50), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 55)
                        }
                    }
                }

                if let mode = model.selectedCategory?.discovery.mode, mode != .entry {
                    FormRow(label: "页面关键词") {
                        TextField("英文逗号分隔；仅筛选发现页面，与附件关键词独立", text: model.categoryBinding(\.discovery.pageKeywords) ?? .constant(""))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                    HStack(spacing: 12) {
                        Text("匹配范围").font(.system(size: 12)).foregroundColor(.secondary)
                        Toggle("页面标题", isOn: model.categoryBinding(\.discovery.scope.title) ?? .constant(true))
                        Toggle("页面网址", isOn: model.categoryBinding(\.discovery.scope.url) ?? .constant(true))
                        Toggle("页面正文", isOn: model.categoryBinding(\.discovery.scope.body) ?? .constant(false))
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    FormRow(label: "页面地址包含") {
                        TextField("英文逗号分隔，命中任一才采集该页附件", text: model.categoryBinding(\.discovery.mustInclude) ?? .constant(""))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                    FormRow(label: "页面地址排除") {
                        TextField("英文逗号分隔，命中任一不采集且不继续发现", text: model.categoryBinding(\.discovery.mustExclude) ?? .constant(""))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                }

                if let mode = model.selectedCategory?.discovery.mode, mode.hasPagination {
                    HStack(spacing: 8) {
                        Text("翻页方式").font(.system(size: 12)).foregroundColor(.secondary)
                        Picker("", selection: model.categoryBinding(\.discovery.pagingMode) ?? .constant(.nextLink)) {
                            ForEach(PagingMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    if model.selectedCategory?.discovery.pagingMode == .nextLink {
                        FormRow(label: "下一页文案") {
                            TextField("英文逗号分隔，匹配链接文字/aria-label/title", text: model.categoryBinding(\.discovery.nextLinkWords) ?? .constant(""))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }
                    } else {
                        FormRow(label: "页码模板") {
                            TextField("含 {页码} 的网址模板，须与入口页面同域", text: model.categoryBinding(\.discovery.pageTemplate) ?? .constant(""))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }
                        HStack(spacing: 10) {
                            FormRow(label: "起始页码") {
                                TextField("", value: model.categoryBinding(\.discovery.startPage) ?? .constant(1), format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 55)
                            }
                            FormRow(label: "最大页码") {
                                TextField("", value: model.categoryBinding(\.discovery.maxPage) ?? .constant(20), format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 55)
                            }
                        }
                    }
                }
            }
            .padding(4)
        } label: {
            Text("页面发现配置").font(.system(size: 12, weight: .semibold))
        }
    }
}

// MARK: - 方案与操作

struct SchemeBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text("配置方案").font(.system(size: 11)).foregroundColor(.secondary)
            Picker("", selection: Binding(
                get: { model.selectedScheme },
                set: { model.switchScheme($0) }
            )) {
                ForEach(model.schemes, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            Button("另存为配置") { model.saveAsScheme() }
                .font(.system(size: 11))
            if model.hasUnsavedChanges {
                Text("● 有未保存改动")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
            Spacer()
        }
    }
}

struct ActionBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button("保存配置") { model.saveConfig() }
            Button("加载配置") { model.loadConfigFromDisk() }
            Button("开始采集") { model.start(forceFull: false) }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.running)
            Button("强制全量采集") { model.start(forceFull: true) }
                .disabled(model.running)
            Button("停止采集") { model.stopRun() }
                .disabled(!model.running)
            Button("清空日志") { model.clearLogs() }
            Button("清空增量记录") { model.clearIncremental() }
                .disabled(model.running)
            Spacer()
        }
    }
}

// MARK: - ⑤ 日志

struct LogPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SectionBox(title: "⑤ 运行日志（按天保存）") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.log.entries) { entry in
                            Text(entry.line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(color(for: entry.type))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
                .onChange(of: model.log.entries.count) { _ in
                    if let last = model.log.entries.last {
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func color(for type: String) -> Color {
        switch type {
        case "失败": return .red
        case "跳过": return .orange
        case "完成": return .green
        case "发现": return .blue
        case "智能": return .purple
        default: return .primary
        }
    }
}

// MARK: - ⑥ 状态栏

struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 14) {
                Text(model.progress.status)
                    .font(.system(size: 12, weight: .semibold))
                if !model.progress.category.isEmpty {
                    Text("分类：\(model.progress.category)")
                }
                Text("页面：\(model.progress.pageIndex)/\(max(model.progress.pageTotal, 0))")
                Text("已访问页面：\(model.progress.visitedPages)")
                Text("已处理附件：\(model.progress.attachmentsProcessed)")
                Text("耗时：\(formatElapsed(model.progress.elapsed))")
                Spacer()
                if model.running {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)

            HStack(spacing: 6) {
                Text("定时运行（启动代理）：以 --silent 参数静默运行一次，不显示窗口。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Button("查看设置方法") { model.showLaunchdHelp = true }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
        }
    }

    private func formatElapsed(_ value: TimeInterval) -> String {
        let total = Int(value)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - 启动代理说明

struct LaunchdHelpView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var executablePath: String {
        Bundle.main.executablePath ?? "/Applications/网页附件采集识别工具.app/Contents/MacOS/网页附件采集识别工具"
    }

    private var plist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.webattach.collector</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
                <string>--silent</string>
            </array>
            <key>StartCalendarInterval</key>
            <dict>
                <key>Hour</key>
                <integer>9</integer>
                <key>Minute</key>
                <integer>0</integer>
            </dict>
            <key>RunAtLoad</key>
            <false/>
        </dict>
        </plist>
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("定时运行设置方法").font(.headline)
            Text("1. 将下方模板保存为 ~/Library/LaunchAgents/com.webattach.collector.plist（可修改运行时间）。\n2. 在终端执行加载命令。\n3. 静默运行使用上次保存的配置，不显示窗口，日志写入 ~/Library/Logs/网页附件采集识别工具/。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            TextEditor(text: .constant(plist))
                .font(.system(size: 10, design: .monospaced))
                .frame(height: 240)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
            HStack {
                Button("复制模板") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plist, forType: .string)
                }
                Button("复制加载命令") {
                    let command = "launchctl load -w ~/Library/LaunchAgents/com.webattach.collector.plist"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 620, height: 470)
    }
}
