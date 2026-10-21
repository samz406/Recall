import SwiftUI
import RecallKit

struct MemoryKnowledgeView: View {
    @EnvironmentObject private var model: RecallAppModel
    let search: String
    @State private var category = 0
    @State private var includeHistory = false
    @State private var visibleCount = 20
    @State private var aliasVisibleCount = 20
    @State private var editing: MemoryClaim?
    @State private var adding = false
    @State private var source: CaptureRecord?
    @State private var forgetting: MemoryClaim?
    @State private var aliases: MemoryEntity?

    private var claims: [MemoryClaim] {
        model.state.memoryKnowledge.claims.filter { item in
            let matches = search.isEmpty || (item.title + item.content).localizedCaseInsensitiveContains(search)
            let kind = category == 0 ? item.kind.isPersonal && item.kind != .person :
                (category == 1 ? item.kind == .person : item.kind == .experience)
            return matches && kind && (includeHistory || [.active, .conflicted, .tentative].contains(item.state))
                && item.scope != .conversation
        }
    }
    private var entities: [MemoryEntity] {
        model.state.memoryKnowledge.entities.filter { search.isEmpty || ($0.name + $0.aliases.joined()).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            introduction
            controls
            if let message = model.memoryMaintenanceMessage {
                Label(message, systemImage: "info.circle").foregroundStyle(.secondary)
            }
            if claims.isEmpty { emptyState }
            ForEach(Array(claims.prefix(visibleCount))) { claim in claimCard(claim) }
            if claims.count > visibleCount { Button("再显示 20 条") { visibleCount += 20 } }
            topicAliases
            retentionSettings
        }
        .onChange(of: category) { _, _ in visibleCount = 20 }
        .onChange(of: search) { _, _ in visibleCount = 20; aliasVisibleCount = 20 }
        .sheet(isPresented: $adding) {
            MemoryAgreementEditor(claim: nil, topics: model.state.memoryKnowledge.entities) { content, scope, scopeID, until in
                await model.saveMemoryAgreement(content: content, scope: scope, scopeID: scopeID, validUntil: until)
            }
        }
        .sheet(item: $editing) { claim in
            MemoryAgreementEditor(claim: claim, topics: model.state.memoryKnowledge.entities) { content, scope, scopeID, until in
                await model.saveMemoryAgreement(content: content, scope: scope, scopeID: scopeID, validUntil: until, replacing: claim)
            }
        }
        .sheet(item: $source) { CaptureDetailSheet(capture: $0).environmentObject(model) }
        .sheet(item: $aliases) { entity in
            MemoryAliasEditor(entity: entity) { await model.saveMemoryAliases(entity: entity, text: $0) }
        }
        .confirmationDialog("忘记这条记忆及其关联记录？", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("移入最近删除", role: .destructive) {
                if let item = forgetting {
                    let records = model.state.captures.filter { item.sourceIDs.contains($0.id) }
                    model.deleteCaptures(records, reason: .noLongerNeeded, suppressSimilar: false)
                }
                forgetting = nil
            }
            Button("取消", role: .cancel) { forgetting = nil }
        } message: {
            Text("关联原始记录和依赖这些记录的总结、回答及提醒会一起移除，七天内可以在‘最近删除’恢复。")
        }
    }
    private var introduction: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "brain.head.profile").font(.system(size: 30)).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 8) {
                Text("让每次积累，都在下次用得上").font(.title2.bold())
                Text("回看 Recall 正在使用的约定、人物线索和历史经验。每条都保留依据，你可以随时更正、停用或忘记。")
                    .foregroundStyle(.secondary)
                if let date = model.state.memoryKnowledge.updatedAt {
                    Text("最近整理 " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("查看记忆", selection: $category) {
                Text("约定与偏好").tag(0); Text("人物与关系").tag(1); Text("历史经验").tag(2)
            }.pickerStyle(.segmented).frame(maxWidth: 500)
            HStack {
                Toggle("显示旧版本和已停用内容", isOn: $includeHistory).toggleStyle(.checkbox)
                Spacer()
                Button("记下一条约定") { adding = true }.buttonStyle(.borderedProminent)
                Button { model.organizeMemoryNow() } label: {
                    Label(model.isOrganizingMemory ? "正在整理…" : "立即整理", systemImage: "arrow.triangle.2.circlepath")
                }.disabled(model.isOrganizingMemory)
            }
        }
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(search.isEmpty ? "还没有这一类记忆" : "没有找到相关记忆").font(.headline)
            Text(category == 2 ? "同一件事有明确的问题、处理经过与完成结果后，会在这里保留原始过程。不同条件下，过去的方法仍需重新核对。" :
                 "你可以在问一问里说‘记住：以后工作周报简洁一点’，也可以直接补充约定。普通阅读材料不会被当作你的偏好。")
                .foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
    }
    private func claimCard(_ claim: MemoryClaim) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(claim.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Text(claim.state.title).font(.caption).foregroundStyle(claim.state == .active ? Color.blue : Color.secondary)
            }
            if claim.content != claim.title { Text(claim.content).textSelection(.enabled) }
            HStack(spacing: 16) {
                Text(claim.scope.title)
                Text(claim.explicit ? "本人明确约定" : "来自本人表达与原始记录")
                Text(claim.date.formatted(date: .abbreviated, time: .omitted))
            }.font(.caption).foregroundStyle(.secondary)
            if claim.state == .conflicted {
                Text("发现了不同说法，当前不会作为稳定偏好使用。更正后可确定今后使用的版本。")
                    .font(.callout).foregroundStyle(.orange)
            }
            if claim.kind == .experience {
                Text("保留的是当时记录中的过程与结果；不代表本次问题具有相同原因。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Menu("查看依据（\(claim.sourceIDs.count)）") {
                    ForEach(model.state.captures.filter { claim.sourceIDs.contains($0.id) }) { record in
                        Button((record.sourceAppName ?? "原始记录") + " · " + record.createdAt.formatted()) { source = record }
                    }
                }
                Button("更正") { editing = claim }
                Spacer()
                Menu {
                    if claim.state == .active { Button("停用这条记忆") { model.retireMemory(claim) } }
                    Button("忘记关联记录…", role: .destructive) { forgetting = claim }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
    }
    private var topicAliases: some View {
        DisclosureGroup("主题与人物的别名") {
            VStack(alignment: .leading, spacing: 14) {
                Text("为常用简称或不同叫法建立关联，问一问会据此补查原始记录。")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(Array(entities.prefix(aliasVisibleCount))) { entity in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entity.name)
                            if !entity.aliases.isEmpty { Text(entity.aliases.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("编辑别名") { aliases = entity }
                    }
                }
                if entities.count > aliasVisibleCount { Button("再显示 20 个主题") { aliasVisibleCount += 20 } }
            }.padding(.top, 16)
        }.padding(20).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
    }
    private var retentionSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("整理与保留").font(.headline)
            Toggle("在后台整理已有记录", isOn: Binding(get: { model.state.memoryKnowledgeSettings.automaticOrganization }, set: { value in
                var settings = model.state.memoryKnowledgeSettings; settings.automaticOrganization = value; model.updateMemorySettings(settings)
            }))
            Toggle("单独保留我明确要求记住的约定", isOn: Binding(get: { model.state.memoryKnowledgeSettings.retainExplicitMemories }, set: { value in
                var settings = model.state.memoryKnowledgeSettings; settings.retainExplicitMemories = value; model.updateMemorySettings(settings)
            }))
            Text("后台只整理已保存的文本。原始截图与文本仍按‘记录事件’里的期限清理；明确约定单独保留必要文本依据，直到你停用、忘记或关闭此项。应用关闭时，到期内容会在下次启动后清理。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
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
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(claim == nil ? "记下一条约定" : "更正记忆").font(.title2.bold())
            Text("写下具体内容与适用范围。更正会保留旧版本，并停止使用依赖旧说法的结果。")
                .foregroundStyle(.secondary)
            TextEditor(text: $content).font(.body).frame(height: 150).padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            Picker("适用范围", selection: $scope) {
                ForEach(MemoryScope.allCases.filter { $0 != .conversation }, id: \.self) { Text($0.title).tag($0) }
            }
            if scope == .project {
                Picker("适用主题", selection: $subjectID) {
                    Text("选择主题").tag("")
                    ForEach(topics) { Text($0.name).tag($0.id) }
                }
            }
            Toggle("设置有效期", isOn: $expires)
            if expires { DatePicker("有效至", selection: $until, in: Date.now...) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "正在保存…" : "保存") {
                    saving = true
                    Task { if await save(content, scope, scope == .project ? subjectID : nil, expires ? until : nil) { dismiss() }; saving = false }
                }.buttonStyle(.borderedProminent).disabled(saving || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.count > 800 || (scope == .project && subjectID.isEmpty))
            }
        }.padding(28).frame(width: 620).disabled(saving).interactiveDismissDisabled(saving)
            .onAppear {
                content = claim?.content ?? ""; scope = claim?.scope ?? .global; subjectID = claim?.scopeID ?? ""
                expires = claim?.validUntil != nil; until = claim?.validUntil ?? Date.now.addingTimeInterval(86_400 * 7)
            }
    }
}

private struct MemoryAliasEditor: View {
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
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer(); Button("取消") { dismiss() }
                Button("保存") { saving = true; Task { if await save(text) { dismiss() }; saving = false } }
                    .buttonStyle(.borderedProminent).disabled(saving)
            }
        }.padding(28).frame(width: 560).onAppear { text = entity.aliases.joined(separator: "，") }
    }
}
