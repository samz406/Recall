import SwiftUI
import RecallKit

struct MemoryKnowledgeView: View {
    @EnvironmentObject private var model: RecallAppModel
    let search: String
    @Binding var adding: Bool
    @State private var draft = ""
    @State private var query = ""
    @State private var category: MemoryLibraryCategory = .all
    @State private var includeHistory = false
    @State private var visibleCount = 20
    @State private var saving = false
    @State private var message: String?
    @State private var editing: MemoryClaim?
    @State private var aliases: MemoryEntity?
    @State private var source: CaptureRecord?
    @State private var forgetting: MemoryClaim?
    @State private var showsDiagnostics = false

    private var active: [MemoryClaim] {
        model.state.memoryKnowledge.claims.filter { MemoryLibraryCategory.all.includes($0.kind) && $0.scope != .conversation && $0.usable() }
    }
    private var rows: [MemoryClaim] {
        model.state.memoryKnowledge.claims.filter {
            category.includes($0.kind) && $0.scope != .conversation && ($0.usable() || includeHistory)
                && (query.isEmpty || ($0.title + $0.content).localizedCaseInsensitiveContains(query))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            Text(RecallLocalization.both("让 Recall 记住你的背景和习惯，减少反复交代。", "Help Recall remember your background and preferences.")).foregroundStyle(RecallPalette.secondary)
            if !model.state.memoryKnowledgeSettings.referencesEnabled {
                Text(RecallLocalization.both("当前已暂停参考个人信息，可在设置 → 记忆整理中恢复。", "Personal context is paused. Resume it in Settings → Memory.")).font(.caption).foregroundStyle(RecallPalette.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                TextField(RecallLocalization.both("希望 Recall 以后记住什么？", "What should Recall remember for later?"), text: $draft, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.plain).onSubmit { remember() }
                    .accessibilityIdentifier("personal-memory-input")
                Button(RecallLocalization.both(saving ? "保存中…" : "记住", saving ? "Saving…" : "Remember"), action: remember)
                    .buttonStyle(.borderedProminent).disabled(saving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 800)
            }.recallSurface(padding: 16)
            if let message { Text(message).font(.caption).foregroundStyle(RecallPalette.secondary) }
            if active.isEmpty && !includeHistory {
                VStack(alignment: .leading, spacing: 10) {
                    Text(RecallLocalization.both("从一句话开始", "Start with one sentence")).font(.headline)
                    Text(RecallLocalization.both("例如：以后回答先给结论，再展开细节。下次相关回答会参考这个要求。", "For example: Give the conclusion first, then the details. Recall can use this in future answers."))
                        .foregroundStyle(RecallPalette.secondary)
                    Button(RecallLocalization.both("填入这个示例", "Use this example")) { draft = RecallLocalization.both("以后回答先给结论，再展开细节", "Give the conclusion first, then the details") }.buttonStyle(.plain).foregroundStyle(RecallPalette.accent)
                    Text(RecallLocalization.both("也可以在“问一问”中直接说“记住：……”", "You can also say “Remember: …” in Ask.")).font(.caption).foregroundStyle(RecallPalette.secondary)
                }.recallSurface()
            }
            HStack {
                if active.count > 8 || !query.isEmpty {
                    TextField(RecallLocalization.both("搜索记住的内容", "Search memories"), text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                    Menu(category.title) {
                        ForEach(MemoryLibraryCategory.allCases, id: \.self) { value in Button(value.title) { category = value } }
                    }.fixedSize()
                }
                Spacer()
                Menu {
                    Toggle(RecallLocalization.both("显示已停止使用的内容", "Show inactive memories"), isOn: $includeHistory)
                    Button(RecallLocalization.both("查看整理详情", "Organization details")) { showsDiagnostics = true }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel(RecallLocalization.both("关于我的更多操作", "More personal memory actions"))
            }
            ForEach(Array(rows.prefix(visibleCount))) { claim in
                VStack(alignment: .leading, spacing: 10) {
                    Text(claim.content).font(RecallTypography.body).textSelection(.enabled)
                    HStack(spacing: 10) {
                        Text(claim.scope.title).font(.caption).foregroundStyle(RecallPalette.secondary)
                        if !claim.usable() { Text(claim.state.title).font(.caption).foregroundStyle(RecallPalette.secondary) }
                        else if !model.state.memoryKnowledgeSettings.references(claim) { Text(RecallLocalization.both("已暂停参考", "Paused")).font(.caption).foregroundStyle(RecallPalette.secondary) }
                        Spacer()
                        Button(RecallLocalization.both("修改", "Edit")) { editing = claim }.buttonStyle(.plain)
                        Menu {
                            if claim.usable() {
                                Button(RecallLocalization.both("不再记住这条", "Forget this memory"), role: .destructive) { forgetting = claim }
                                Button(RecallLocalization.both(model.state.memoryKnowledgeSettings.references(claim) ? "暂停参考" : "恢复参考", model.state.memoryKnowledgeSettings.references(claim) ? "Pause use" : "Resume use")) { model.setMemoryReference(claim, enabled: !model.state.memoryKnowledgeSettings.references(claim)) }
                            }
                            if let entity = model.state.memoryKnowledge.entities.first(where: { $0.id == claim.subjectID && $0.kind == "person" }) {
                                Button(RecallLocalization.text("管理人物别名")) { aliases = entity }
                            }
                            Menu(RecallLocalization.both("查看来源", "View sources")) {
                                ForEach(claim.sourceIDs.compactMap { model.memoryWorkspace?.sources[$0] }) { record in
                                    Button((record.sourceAppName ?? "记录") + " · " + record.createdAt.formatted()) { source = record }
                                }
                            }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    }
                }.recallSurface(padding: 18)
            }
            if rows.count > visibleCount { Button(RecallLocalization.text("再显示 20 条")) { visibleCount += 20 } }
        }
        .onChange(of: query) { _, _ in visibleCount = 20 }
        .onChange(of: category) { _, _ in visibleCount = 20 }
        .onAppear { if model.knowledgeToOpen != nil { includeHistory = true } }
        .sheet(isPresented: $adding) { editor(nil) }
        .sheet(item: $editing) { editor($0) }
        .sheet(item: $aliases) { entity in MemoryAliasEditor(entity: entity) { await model.saveMemoryAliases(entity: entity, text: $0) } }
        .sheet(item: $source) { CaptureDetailSheet(capture: $0).environmentObject(model) }
        .sheet(isPresented: $showsDiagnostics) { MemoryOrganizationDetails().environmentObject(model) }
        .confirmationDialog(RecallLocalization.both("不再参考这条记忆？", "Stop using this memory?"), isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), presenting: forgetting) { target in
            Button(RecallLocalization.both("不再记住", "Forget"), role: .destructive) { model.retireMemory(target); forgetting = nil }
        } message: { _ in Text(RecallLocalization.both("以后不再按这条信息回答。原始记录与已有回顾保留。", "Future answers will stop using this memory. Source records and saved reviews are kept.")) }
    }
    private func editor(_ claim: MemoryClaim?) -> some View {
        MemoryAgreementEditor(claim: claim, topics: model.state.memoryKnowledge.entities.filter { $0.kind == "topic" }) { content, scope, scopeID, until in
            await model.saveMemoryAgreement(content: content, scope: scope, scopeID: scopeID, validUntil: until, replacing: claim)
        }
    }
    private func remember() {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saving, !content.isEmpty, content.count <= 800 else { return }
        saving = true; message = nil
        let directive = MemoryDirective.fromUserInput(content)
        if directive?.scope == .conversation {
            saving = false; message = RecallLocalization.both("这次的要求请在“问一问”中输入。", "Use Ask for a one-time instruction."); return
        }
        Task {
            defer { saving = false }
            if await model.saveMemoryAgreement(content: content, scope: directive?.scope ?? .global, scopeID: directive?.scopeID, validUntil: directive?.validUntil) {
                draft = ""; message = model.noticeMessage
            } else { message = RecallLocalization.both("未能保存，请重试。", "Could not save. Please retry.") }
        }
    }
}

struct MemoryOrganizationSettings: View {
    @EnvironmentObject private var model: RecallAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecallSwitchRow(title: "在问答和回顾中参考关于我的信息", isOn: Binding(get: { model.state.memoryKnowledgeSettings.referencesEnabled }, set: { value in
                var settings = model.state.memoryKnowledgeSettings; settings.referenceInChat = value; model.updateMemorySettings(settings)
            }))
            RecallSwitchRow(title: "自动更新主题小结", isOn: Binding(get: { model.state.memoryKnowledgeSettings.automaticTopicSummaries == true }, set: { value in
                var settings = model.state.memoryKnowledgeSettings; settings.automaticTopicSummaries = value; model.updateMemorySettings(settings)
            }))
            Text(RecallLocalization.both("开启后，使用已配置的模型在后台整理有新内容的主题；可随时暂停，已有内容仍可阅读。", "When enabled, the configured model updates changed topic summaries in the background. You can pause at any time."))
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            RecallSwitchRow(title: "在后台整理已有记录", isOn: Binding(get: { model.state.memoryKnowledgeSettings.automaticOrganization }, set: { value in
                var settings = model.state.memoryKnowledgeSettings; settings.automaticOrganization = value; model.updateMemorySettings(settings)
            }))
            RecallSwitchRow(title: "保留我明确要求记住的内容", isOn: Binding(get: { model.state.memoryKnowledgeSettings.retainExplicitMemories }, set: { value in
                var settings = model.state.memoryKnowledgeSettings; settings.retainExplicitMemories = value; model.updateMemorySettings(settings)
            }))
            Text(RecallLocalization.text("只整理已保存的文本。截图与文本按记录管理中的期限清理；你明确要求记住的必要文字单独保留，直到停用、删除或关闭此项。应用关闭时，到期清理在下次启动后执行。"))
                .font(.caption).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
        }.toggleStyle(.switch).controlSize(.small)
    }
}

private struct MemoryOrganizationDetails: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let summary = model.memoryWorkspace?.summary ?? MemoryOrganizationSummary()
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(RecallLocalization.text("记忆整理详情")).font(.title2.bold()); Spacer(); Button(RecallLocalization.text("完成")) { dismiss() } }
            Text("\(summary.records) 条记录 · \(summary.textRecords) 条含文字 · \(summary.attributedRecords) 条带本人归属")
            Text("\(summary.matters) 个本人事项 · \(summary.references) 个资料主题 · \(summary.agreements) 条明确记忆")
                .foregroundStyle(RecallPalette.secondary)
            Text(RecallLocalization.text("记录数量不等于有效记忆数量。临时表达、归属不明或存在冲突的内容不会直接用于个性化回答。"))
                .font(.callout).foregroundStyle(RecallPalette.secondary)
            if let task = model.tasks.first(where: { $0.kind == "整理记忆" }) { RecallTaskStatusView(task: task) }
            Spacer()
        }.padding(28).frame(width: 620, height: 320)
    }
}

struct MemoryReferenceBrowser: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var limit = 20
    @State private var selected: MemoryClaim?
    var body: some View {
        let rows = model.state.memoryKnowledge.claims.filter { claim in
            claim.kind == .reference && claim.usable() && (query.isEmpty || (claim.title + claim.content).localizedCaseInsensitiveContains(query))
        }
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(RecallLocalization.text("资料与线索")).font(.title2.bold()); Spacer(); Button(RecallLocalization.text("完成")) { dismiss() } }
            Text(RecallLocalization.text("回看保存过的内容。资料中的观点和他人的话不会作为你的个人偏好。"))
                .foregroundStyle(RecallPalette.secondary)
            TextField(RecallLocalization.text("搜索保存的内容"), text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if rows.isEmpty { Text(RecallLocalization.text("暂时没有匹配的资料，可以在时间线查看原始记录。")).foregroundStyle(RecallPalette.secondary) }
                    ForEach(Array(rows.prefix(limit))) { claim in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(claim.title).font(.headline)
                            if claim.title != claim.content { Text(claim.content).lineLimit(5) }
                            Button(RecallLocalization.text("查看原始来源")) { selected = claim }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if rows.count > limit { Button(RecallLocalization.text("再显示 20 条")) { limit += 20 } }
                }
            }
        }.padding(28).frame(width: 720, height: 600).onChange(of: query) { _, _ in limit = 20 }
            .sheet(item: $selected) { claim in RecallSourcesView(title: claim.title, ids: claim.sourceIDs).environmentObject(model) }
    }
}

struct MemoryAgreementEditor: View {
    @Environment(\.dismiss) private var dismiss
    let claim: MemoryClaim?
    let topics: [MemoryEntity]
    var initialTopic: MemoryEntity? = nil
    let save: (String, MemoryScope, String?, Date?) async -> Bool
    @State private var content = ""
    @State private var scope: MemoryScope = .global
    @State private var subjectID = ""
    @State private var expires = false
    @State private var until = Date.now.addingTimeInterval(86_400 * 7)
    @State private var saving = false
    @State private var advanced = false
    @State private var scopeChanged = false
    @State private var expiryChanged = false
    @State private var saveError: String?
    private var suggested: MemoryDirective? { MemoryDirective.fromUserInput(content) }
    private var conversationRequest: Bool { suggested?.scope == .conversation }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(claim == nil ? "记住一件事" : "更正记忆").font(.title2.bold())
            Text(RecallLocalization.both("写下一句以后希望参考的信息，适用范围可按需调整。", "Write something to remember for later. Adjust the scope if needed."))
                .foregroundStyle(RecallPalette.secondary)
            TextEditor(text: $content).font(.body).scrollContentBackground(.hidden).frame(height: 150).padding(10)
                .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            DisclosureGroup(RecallLocalization.both("适用范围与有效期", "Scope and expiry"), isExpanded: $advanced) {
            Picker(RecallLocalization.text("适用范围"), selection: Binding(get: { scope }, set: { scope = $0; scopeChanged = true })) {
                ForEach(MemoryScope.allCases.filter { $0 != .conversation }, id: \.self) { Text($0.title).tag($0) }
            }
            if scope == .project {
                Picker(RecallLocalization.text("适用主题"), selection: $subjectID) {
                    Text(RecallLocalization.text("选择主题")).tag("")
                    ForEach(topics) { Text($0.name).tag($0.id) }
                    if !subjectID.isEmpty && !topics.contains(where: { $0.id == subjectID }) {
                        Text(RecallLocalization.text("内容中提及的项目")).tag(subjectID)
                    }
                }
            }
            Toggle(RecallLocalization.text("设置有效期"), isOn: Binding(get: { expires }, set: { expires = $0; expiryChanged = true }))
            if expires { DatePicker("有效至", selection: Binding(get: { until }, set: { until = $0; expiryChanged = true }), in: Date.now...) }
            }
            if conversationRequest {
                Text(RecallLocalization.text("‘这次/本次’的要求只适用于当前会话，请在问一问中输入。"))
                    .font(.callout).foregroundStyle(RecallPalette.secondary)
            }
            if let saveError { Text(saveError).font(.callout).foregroundStyle(RecallPalette.warning) }
            HStack {
                Spacer()
                Button(RecallLocalization.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "正在保存…" : "保存") {
                    saving = true
                    Task {
                        if await save(content, scope, scope == .project ? subjectID : nil, expires ? until : nil) { dismiss() }
                        else { saveError = "未能保存，请检查内容、适用范围与有效期后重试。" }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || conversationRequest || (expires && until <= .now) || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.count > 800 || (scope == .project && subjectID.isEmpty))
            }
        }.padding(28).frame(width: 620).disabled(saving).interactiveDismissDisabled(saving)
            .onAppear {
                content = claim?.content ?? ""; scope = claim?.scope ?? (initialTopic == nil ? .global : .project); subjectID = claim?.scopeID ?? initialTopic?.id ?? ""
                scopeChanged = initialTopic != nil
                expires = claim?.validUntil != nil; until = max(Date.now, claim?.validUntil ?? Date.now.addingTimeInterval(86_400 * 7))
            }
            .onChange(of: content) { _, _ in
                saveError = nil
                guard claim == nil, let suggested, !conversationRequest else { return }
                if !scopeChanged { scope = suggested.scope; subjectID = suggested.scopeID ?? "" }
                if !expiryChanged {
                    expires = suggested.validUntil != nil
                    if let date = suggested.validUntil { until = date }
                }
            }
    }
}

struct MemoryAliasEditor: View {
    @Environment(\.dismiss) private var dismiss
    let entity: MemoryEntity
    let save: (String) async -> Bool
    @State private var text = ""
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(RecallLocalization.text("编辑别名")).font(.title2.bold())
            Text(entity.name).font(.headline)
            TextField(RecallLocalization.text("用逗号分隔，例如：账单导出、报表下载"), text: $text).textFieldStyle(.roundedBorder)
            Text(RecallLocalization.text("最多 12 个别名，每个 2–60 字。别名只帮助定位内容，不会合并不同人的身份或修改原始事实。"))
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            HStack {
                Spacer(); Button(RecallLocalization.text("取消")) { dismiss() }
                Button(RecallLocalization.text("保存")) { saving = true; Task { if await save(text) { dismiss() }; saving = false } }
                    .buttonStyle(.borderedProminent).disabled(saving)
            }
        }.padding(28).frame(width: 560).onAppear { text = entity.aliases.joined(separator: "，") }
    }
}
