import SwiftUI
import RecallKit

struct MemoryKnowledgeView: View {
    @EnvironmentObject private var model: RecallAppModel
    let search: String
    @State private var category: MemoryLibraryCategory = .all
    @State private var includeHistory = false
    @State private var includeUncertain = false
    @State private var visibleCount = 20
    @State private var editing: MemoryClaim?
    @Binding var adding: Bool
    @State private var draft = ""
    @State private var query = ""
    @State private var projectBackground = false
    @State private var savingDraft = false
    @State private var draftError: String?
    @State private var source: CaptureRecord?
    @State private var forgetting: MemoryClaim?
    @State private var aliases: MemoryEntity?
    @State private var showsDiagnostics = false
    @State private var showsReferences = false
    @State private var handledID: UUID?

    private var claims: [MemoryClaim] {
        model.state.memoryKnowledge.claims.filter { item in
            let text = query.isEmpty ? search : query
            let matches = text.isEmpty || (item.title + item.content).localizedCaseInsensitiveContains(text)
            return matches && (projectBackground ? item.scope == .project && item.kind.isPersonal : category.includes(item.kind)) && item.scope != .conversation
                && (item.usable() || (includeUncertain && [.tentative, .conflicted].contains(item.state)) || includeHistory)
        }.sorted { a, b in
            if a.id == model.knowledgeToOpen { return b.id != a.id }
            if b.id == model.knowledgeToOpen { return false }
            return a.updatedAt == b.updatedAt ? a.id.uuidString < b.id.uuidString : a.updatedAt > b.updatedAt
        }
    }
    private var updating: Bool { model.isOrganizingMemory || model.isBuildingMatters }
    var body: some View {
        let rows = claims
        LazyVStack(alignment: .leading, spacing: 18) {
            controls
            if updating || model.tasks.first(where: { $0.kind == "整理记忆" })?.state == .failed { maintenanceStatus }
            if model.state.memoryKnowledge.claims.count > 8 {
                TextField("搜索长期记忆", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 340)
            }
            if let message = model.memoryMaintenanceMessage {
                Text(message).font(.callout).foregroundStyle(RecallPalette.secondary)
            }
            if rows.isEmpty && !updating { emptyState }
            ForEach(Array(rows.prefix(visibleCount))) { claim in claimCard(claim) }
            if rows.count > visibleCount { Button("再显示 20 条") { visibleCount += 20 } }
        }
        .onChange(of: category) { _, _ in visibleCount = 20 }
        .onChange(of: search) { _, _ in visibleCount = 20 }
        .onAppear { openRequestedMemory() }
        .onChange(of: model.knowledgeToOpen) { _, _ in handledID = nil; openRequestedMemory() }
        .onChange(of: model.memoryWorkspace?.revision) { _, _ in openRequestedMemory() }
        .sheet(isPresented: $adding) {
            MemoryAgreementEditor(claim: nil, topics: model.state.memoryKnowledge.entities.filter { $0.kind == "topic" }) { content, scope, scopeID, until in
                await model.saveMemoryAgreement(content: content, scope: scope, scopeID: scopeID, validUntil: until)
            }
        }
        .sheet(item: $editing) { claim in
            MemoryAgreementEditor(claim: claim, topics: model.state.memoryKnowledge.entities.filter { $0.kind == "topic" }) { content, scope, scopeID, until in
                await model.saveMemoryAgreement(content: content, scope: scope, scopeID: scopeID, validUntil: until, replacing: claim)
            }
        }
        .sheet(item: $source) { CaptureDetailSheet(capture: $0).environmentObject(model) }
        .sheet(item: $aliases) { entity in
            MemoryAliasEditor(entity: entity) { await model.saveMemoryAliases(entity: entity, text: $0) }
        }
        .sheet(isPresented: $showsDiagnostics) { MemoryOrganizationDetails().environmentObject(model) }
        .sheet(isPresented: $showsReferences) { MemoryReferenceBrowser().environmentObject(model) }
        .confirmationDialog("忘记这条记忆及其关联记录？", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("移入最近删除", role: .destructive) {
                if let item = forgetting {
                    let ids = Set(item.sourceIDs)
                    model.deleteCaptures(model.state.captures.filter { ids.contains($0.id) }, reason: .noLongerNeeded, suppressSimilar: false)
                }
                forgetting = nil
            }
            Button("取消", role: .cancel) { forgetting = nil }
        } message: {
            Text("关联原始记录和依赖这些记录的总结、回答及提醒会一起移除，七天内可以在‘最近删除’恢复。")
        }
    }
    private func openRequestedMemory() {
        guard let id = model.knowledgeToOpen, id != handledID,
              let claim = model.state.memoryKnowledge.claims.first(where: { $0.id == id }) else { return }
        handledID = id
        if claim.kind == .reference { showsReferences = true; return }
        category = .all
        includeHistory = !claim.usable()
        visibleCount = max(20, (claims.firstIndex { $0.id == id } ?? 0) + 1)
    }
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { categories; Spacer(minLength: 8); referenceToggle; moreActions }
            VStack(alignment: .leading, spacing: 12) { categories; HStack { referenceToggle; Spacer(); moreActions } }
        }
    }
    private var categories: some View {
        HStack(spacing: 6) {
            ForEach([MemoryLibraryCategory.all, .preferences, .people, .agreements], id: \.self) { value in
                RecallFilterChip(title: categoryTitle(value) + " \(count(value))", selected: !projectBackground && category == value) { category = value; projectBackground = false }
            }
            RecallFilterChip(title: "项目背景 \(model.state.memoryKnowledge.claims.filter { $0.usable() && $0.kind.isPersonal && $0.scope == .project }.count)", selected: projectBackground) { projectBackground = true }
        }
    }
    private func categoryTitle(_ value: MemoryLibraryCategory) -> String {
        switch value { case .all: "全部"; case .preferences: "偏好"; case .people: "人物"; case .agreements: "约定"; case .experiences: "经验" }
    }
    private func count(_ value: MemoryLibraryCategory) -> Int {
        model.state.memoryKnowledge.claims.filter { value.includes($0.kind) && $0.usable() && $0.scope != .conversation }.count
    }
    private var referenceToggle: some View {
        Toggle("对话时参考长期记忆", isOn: Binding(get: { model.state.memoryKnowledgeSettings.referencesEnabled }, set: { value in
            var settings = model.state.memoryKnowledgeSettings; settings.referenceInChat = value; model.updateMemorySettings(settings)
        })).toggleStyle(.switch).controlSize(.small).font(.caption).fixedSize()
    }
    private var moreActions: some View {
        Menu {
            Button("更新记忆") { model.organizeMemoryNow() }.disabled(updating)
            Toggle("显示待核实的线索", isOn: $includeUncertain)
            Toggle("显示旧版本和已停用内容", isOn: $includeHistory)
            Button("历史经验") { category = .experiences; projectBackground = false }
            Button("资料与线索") { showsReferences = true }
            Divider(); Button("查看整理详情") { showsDiagnostics = true }
        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多记忆选项")
    }
    private var maintenanceStatus: some View {
        HStack(spacing: 10) {
            if updating {
                ProgressView().controlSize(.small).frame(width: 18, height: 18)
                Text(model.tasks.first { $0.kind == "整理记忆" && $0.isRunning }?.phase ?? "正在更新记忆，已有内容仍可查看")
            } else if let task = model.tasks.first(where: { $0.kind == "整理记忆" }), task.state == .failed {
                Image(systemName: "exclamationmark.circle"); Text("更新未完成，可从更多菜单重试。")
            } else if let date = model.state.memoryKnowledge.updatedAt {
                Text("最近更新 " + date.formatted(date: .abbreviated, time: .shortened))
            }
            Spacer()
        }.font(.caption).foregroundStyle(RecallPalette.secondary)
    }
    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "brain.head.profile").font(.system(size: 36, weight: .light)).foregroundStyle(RecallPalette.accent)
            Text(query.isEmpty && search.isEmpty ? "还没有这类长期记忆" : "没有找到相关记忆").font(.headline)
            Text("保留你明确表达的偏好、人物和约定。临时要求与阅读材料不会自动保存为个人偏好。")
                .font(.callout).foregroundStyle(RecallPalette.secondary).multilineTextAlignment(.center).frame(maxWidth: 580)
            HStack(alignment: .top, spacing: 12) {
                TextField("希望 Recall 记住什么？", text: $draft, axis: .vertical).lineLimit(2...5).textFieldStyle(.plain).onSubmit { saveDraft() }
                Button(savingDraft ? "保存中…" : "记住", action: saveDraft).buttonStyle(.borderedProminent).disabled(savingDraft || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 800)
            }.recallSurface(padding: 14).frame(maxWidth: 600)
            if let draftError { Text(draftError).font(.caption).foregroundStyle(RecallPalette.warning) }
            Text("也可以从一句话开始，填写后再保存").font(.caption).foregroundStyle(RecallPalette.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { exampleButtons }
                VStack(spacing: 10) { exampleButtons }
            }.frame(maxWidth: 720)
        }.frame(maxWidth: .infinity, minHeight: 420)
    }
    @ViewBuilder private var exampleButtons: some View {
        ForEach(["以后回答简洁一点，先结论后细节", "我希望记住的人物信息：", "以后写工作周报时，只写工作内容"], id: \.self) { example in
            Button { draft = example } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Text(example).font(.callout).lineLimit(2)
                    Text("填入示例 +").font(.caption).foregroundStyle(RecallPalette.accent)
                }.frame(maxWidth: .infinity, alignment: .leading).recallSurface(padding: 14)
            }.buttonStyle(.plain)
        }
    }
    private func saveDraft() {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !savingDraft, !content.isEmpty, content.count <= 800 else { return }
        savingDraft = true; draftError = nil
        let directive = MemoryDirective.parse("记住：" + content)
        Task {
            if await model.saveMemoryAgreement(content: content, scope: directive?.scope ?? .global, scopeID: directive?.scopeID, validUntil: directive?.validUntil) { draft = "" }
            else { draftError = "未能保存，请检查内容后重试。" }
            savingDraft = false
        }
    }
    private func claimCard(_ claim: MemoryClaim) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(claim.content).font(RecallTypography.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    RecallStatusBadge(title: claim.kind.title)
                    Text((claim.explicit ? "你明确说过" : "来自已有记录") + " · " + claim.date.formatted(date: .abbreviated, time: .omitted))
                    if !claim.usable() { Text(claim.state.title) }
                    if !model.state.memoryKnowledgeSettings.references(claim) { Text("已暂停参考") }
                }.font(.caption).foregroundStyle(RecallPalette.secondary)
                if let until = claim.validUntil { Text("有效至 " + until.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(RecallPalette.secondary) }
            }
            Spacer(minLength: 0)
            Button("编辑") { editing = claim }.buttonStyle(.plain)
            Button("删除") { forgetting = claim }.buttonStyle(.plain)
            Menu {
                Menu("查看来源") {
                    ForEach(claim.sourceIDs.compactMap { model.memoryWorkspace?.sources[$0] }) { record in
                        Button((record.sourceAppName ?? "原始记录") + " · " + record.createdAt.formatted()) { source = record }
                    }
                }
                if let entity = model.state.memoryKnowledge.entities.first(where: { $0.id == claim.subjectID && $0.kind == "person" }) {
                    Button("管理人物别名") { aliases = entity }
                }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多记忆操作")
            Toggle("参考这条记忆", isOn: Binding(get: { !(model.state.memoryKnowledgeSettings.disabledClaimKeys ?? []).contains(claim.key) }, set: { model.setMemoryReference(claim, enabled: $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!claim.usable())
        }.font(.caption).recallSurface(padding: 18)
    }

}

struct MemoryOrganizationSettings: View {
    @EnvironmentObject private var model: RecallAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecallSwitchRow(title: "在后台整理已有记录", isOn: Binding(get: { model.state.memoryKnowledgeSettings.automaticOrganization }, set: { value in
                var settings = model.state.memoryKnowledgeSettings; settings.automaticOrganization = value; model.updateMemorySettings(settings)
            }))
            RecallSwitchRow(title: "保留我明确要求记住的内容", isOn: Binding(get: { model.state.memoryKnowledgeSettings.retainExplicitMemories }, set: { value in
                var settings = model.state.memoryKnowledgeSettings; settings.retainExplicitMemories = value; model.updateMemorySettings(settings)
            }))
            Text("只整理已保存的文本。截图与文本按记录管理中的期限清理；你明确要求记住的必要文字单独保留，直到停用、删除或关闭此项。应用关闭时，到期清理在下次启动后执行。")
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
            HStack { Text("记忆整理详情").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("\(summary.records) 条记录 · \(summary.textRecords) 条含文字 · \(summary.attributedRecords) 条带本人归属")
            Text("\(summary.matters) 个本人事项 · \(summary.references) 个资料主题 · \(summary.agreements) 条明确记忆")
                .foregroundStyle(RecallPalette.secondary)
            Text("记录数量不等于有效记忆数量。临时表达、归属不明或存在冲突的内容不会直接用于个性化回答。")
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
            HStack { Text("资料与线索").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("回看保存过的内容。资料中的观点和他人的话不会作为你的个人偏好。")
                .foregroundStyle(RecallPalette.secondary)
            TextField("搜索保存的内容", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if rows.isEmpty { Text("暂时没有匹配的资料，可以在时间线查看原始记录。").foregroundStyle(RecallPalette.secondary) }
                    ForEach(Array(rows.prefix(limit))) { claim in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(claim.title).font(.headline)
                            if claim.title != claim.content { Text(claim.content).lineLimit(5) }
                            Button("查看原始来源") { selected = claim }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if rows.count > limit { Button("再显示 20 条") { limit += 20 } }
                }
            }
        }.padding(28).frame(width: 720, height: 600).onChange(of: query) { _, _ in limit = 20 }
            .sheet(item: $selected) { claim in RecallSourcesView(title: claim.title, ids: claim.sourceIDs).environmentObject(model) }
    }
}

private struct MemoryAgreementEditor: View {
    @Environment(\.dismiss) private var dismiss
    let claim: MemoryClaim?
    let topics: [MemoryEntity]
    let save: (String, MemoryScope, String?, Date?) async -> Bool
    @State private var content = ""
    @State private var scope: MemoryScope = .global
    @State private var subjectID = ""
    @State private var expires = false
    @State private var until = Date.now.addingTimeInterval(86_400 * 7)
    @State private var saving = false
    @State private var scopeChanged = false
    @State private var expiryChanged = false
    @State private var saveError: String?
    private var suggested: MemoryDirective? { MemoryDirective.parse("记住：" + content) }
    private var conversationRequest: Bool { suggested?.scope == .conversation }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(claim == nil ? "记住一件事" : "更正记忆").font(.title2.bold())
            Text("写下具体内容与适用范围。更正会保留旧版本，并停止使用依赖旧说法的结果。")
                .foregroundStyle(RecallPalette.secondary)
            TextEditor(text: $content).font(.body).scrollContentBackground(.hidden).frame(height: 150).padding(10)
                .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            Picker("适用范围", selection: Binding(get: { scope }, set: { scope = $0; scopeChanged = true })) {
                ForEach(MemoryScope.allCases.filter { $0 != .conversation }, id: \.self) { Text($0.title).tag($0) }
            }
            if scope == .project {
                Picker("适用主题", selection: $subjectID) {
                    Text("选择主题").tag("")
                    ForEach(topics) { Text($0.name).tag($0.id) }
                    if !subjectID.isEmpty && !topics.contains(where: { $0.id == subjectID }) {
                        Text("内容中提及的项目").tag(subjectID)
                    }
                }
            }
            Toggle("设置有效期", isOn: Binding(get: { expires }, set: { expires = $0; expiryChanged = true }))
            if expires { DatePicker("有效至", selection: Binding(get: { until }, set: { until = $0; expiryChanged = true }), in: Date.now...) }
            if conversationRequest {
                Text("‘这次/本次’的要求只适用于当前会话，请在问一问中输入。")
                    .font(.callout).foregroundStyle(RecallPalette.secondary)
            }
            if let saveError { Text(saveError).font(.callout).foregroundStyle(RecallPalette.warning) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
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
                content = claim?.content ?? ""; scope = claim?.scope ?? .global; subjectID = claim?.scopeID ?? ""
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
            Text("编辑别名").font(.title2.bold())
            Text(entity.name).font(.headline)
            TextField("用逗号分隔，例如：账单导出、报表下载", text: $text).textFieldStyle(.roundedBorder)
            Text("最多 12 个别名，每个 2–60 字。别名只帮助定位内容，不会合并不同人的身份或修改原始事实。")
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            HStack {
                Spacer(); Button("取消") { dismiss() }
                Button("保存") { saving = true; Task { if await save(text) { dismiss() }; saving = false } }
                    .buttonStyle(.borderedProminent).disabled(saving)
            }
        }.padding(28).frame(width: 560).onAppear { text = entity.aliases.joined(separator: "，") }
    }
}
