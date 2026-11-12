import SwiftUI
import RecallKit

private enum MatterWorkspaceTab: String { case topics = "记忆主题", knowledge = "长期记忆" }

struct MatterWorkspaceView: View {
    @EnvironmentObject private var model: RecallAppModel
    @AppStorage("recall.memory.tab") private var tab: MatterWorkspaceTab = .topics
    @State private var search = ""
    @State private var filter = 0
    @State private var limit = 20
    @State private var selectedID: String?
    @State private var adding = false
    @State private var addingTitle = ""
    @State private var addingMemory = false
    @State private var merging = false
    @State private var corrections = false
    @State private var references = false
    let continueChat: (String) -> Void

    private var files: [MatterFile] {
        model.matterFiles.filter { file in
            (search.isEmpty || (file.title + file.events.map(\.detail).joined(separator: " ")).localizedCaseInsensitiveContains(search))
                && (filter == 0 || (filter == 1 ? file.latest.status.isOpenMatter : file.latest.status == .completed))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecallPageHeader(title: "记忆", subtitle: "找回一件事的经过，让 Recall 更了解你") {
                if tab == .topics {
                    Button { addingTitle = ""; adding = true } label: { Label(RecallLocalization.text("补充记录"), systemImage: "plus") }.buttonStyle(.borderedProminent)
                    Menu {
                        Button(RecallLocalization.text("合并主题")) { merging = true }
                        Button(RecallLocalization.text("资料与线索")) { references = true }
                        Button(RecallLocalization.text("更正记录")) { corrections = true }
                        Button(RecallLocalization.text("更新记忆")) { model.organizeMemoryNow() }.disabled(model.isBuildingMatters || model.isOrganizingMemory)
                        Toggle(RecallLocalization.text("显示历史经验提示"), isOn: Binding(get: { model.state.experienceHintsEnabled }, set: { model.setExperienceHints($0) }))
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            HStack(spacing: 28) {
                tabButton("主题", english: "Topics", value: .topics)
                tabButton("关于我", english: "About me", value: .knowledge)
                Spacer()
            }.padding(.horizontal, 24).padding(.bottom, 14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if tab == .knowledge {
                        MemoryKnowledgeView(search: "", adding: $addingMemory).environmentObject(model)
                    } else {
                        if !model.matterFiles.isEmpty {
                            HStack(spacing: 8) {
                                RecallFilterChip(title: RecallLocalization.both("最近更新", "Recent"), selected: filter == 0) { filter = 0 }
                                Menu(RecallLocalization.both("筛选", "Filter")) {
                                    Button(RecallLocalization.text("全部")) { filter = 0 }
                                    Button(RecallLocalization.text("进行中")) { filter = 1 }
                                    Button(RecallLocalization.text("已完成")) { filter = 2 }
                                }.fixedSize()
                                Spacer()
                                TextField(RecallLocalization.text("搜索主题或内容"), text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            }
                        }
                        if let message = model.matterBuildMessage { Text(RecallLocalization.text(message)).font(.caption).foregroundStyle(RecallPalette.secondary) }
                        if files.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(RecallLocalization.both(search.isEmpty ? "从一件事开始" : "没有找到相关主题", search.isEmpty ? "Start with a topic" : "No matching topics")).font(.headline)
                                Text(RecallLocalization.both("保存的相关记录会串联在这里。点开主题即可回看进展、结论和来源。", "Related records appear together here. Open a topic to read its progress, conclusions and sources.")).foregroundStyle(RecallPalette.secondary)
                                if search.isEmpty { Button(RecallLocalization.text("补充记录")) { adding = true } }
                                else { Button(RecallLocalization.text("清空搜索")) { search = ""; filter = 0 } }
                            }.recallSurface()
                        }
                        ForEach(Array(files.prefix(limit))) { file in card(file) }
                        if files.count > limit { Button(RecallLocalization.text("再显示 20 条")) { limit += 20 } }
                        if model.state.experienceHintsEnabled, let hint = model.experienceHint {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(RecallLocalization.both("以前的结果，也许能帮上忙", "A past result may help")).font(.headline)
                                Text(hint.past.detail)
                                HStack {
                                    Button(RecallLocalization.both("查看当时主题", "Open past topic")) { selectedID = model.matterFiles.first { $0.events.contains { $0.id == hint.past.id } }?.id }
                                    Button(RecallLocalization.text("不再提示这一条")) { model.dismissExperience(hint) }
                                }
                            }.recallSurface()
                        }
                    }
                }.padding(24).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }.clipped()
        }
        .onAppear { openRequested() }
        .onChange(of: model.navigationRevision) { _, _ in openRequested() }
        .onChange(of: search) { _, _ in limit = 20 }
        .onChange(of: filter) { _, _ in limit = 20 }
        .sheet(isPresented: Binding(get: { selectedID != nil }, set: { if !$0 { selectedID = nil } })) {
            if let id = selectedID { TopicDetailView(topicID: id, continueChat: { value in selectedID = nil; continueChat(value) }).environmentObject(model) }
        }
        .sheet(isPresented: $adding) { ManualMatterSheet(title: addingTitle) { await model.saveManualMatter($0) } }
        .sheet(isPresented: $merging) { TopicMergeSheet().environmentObject(model) }
        .sheet(isPresented: $references) { MemoryReferenceBrowser().environmentObject(model) }
        .sheet(isPresented: $corrections) { MatterCorrectionHistorySheet().environmentObject(model) }
    }
    private func tabButton(_ title: String, english: String, value: MatterWorkspaceTab) -> some View {
        Button { tab = value } label: {
            Text(RecallLocalization.both(title, english)).font(.headline).foregroundStyle(tab == value ? RecallPalette.accent : RecallPalette.secondary)
                .padding(.vertical, 9).overlay(alignment: .bottom) { if tab == value { Rectangle().fill(RecallPalette.accent).frame(height: 2) } }
        }.buttonStyle(.plain).accessibilityAddTraits(tab == value ? .isSelected : [])
    }
    private func card(_ file: MatterFile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { selectedID = file.id } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(file.title).font(.headline)
                        Spacer()
                        Text(RecallLocalization.text(file.latest.status.manualMatterLabel)).font(.caption).foregroundStyle(RecallPalette.secondary)
                    }
                    Text(TopicReading(file: file, review: model.state.topicReviews.first { $0.id == file.id }).overview)
                        .font(RecallTypography.body).foregroundStyle(RecallPalette.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("open-topic-" + file.id)
            HStack(spacing: 12) {
                Text(file.latest.date.formatted(date: .abbreviated, time: .omitted) + RecallLocalization.both(" · \(file.evidenceIDs.count) 条来源", " · \(file.evidenceIDs.count) sources")).font(.caption).foregroundStyle(RecallPalette.secondary)
                Spacer()
                if model.completingMatterIDs.contains(file.id) { Text(RecallLocalization.both("保存中…", "Saving…")).font(.caption) }
                Button(RecallLocalization.both("继续问", "Ask about this")) { continueChat(file.id) }.buttonStyle(.bordered)
                Menu {
                    Button(RecallLocalization.both("补充进展", "Add progress")) { addingTitle = file.title; adding = true }
                    if file.latest.status.isOpenMatter {
                        Button(RecallLocalization.both("标记完成", "Mark complete")) { Task { await model.completeMatter(file) } }.disabled(model.completingMatterIDs.contains(file.id))
                    } else if model.state.matterCorrections.contains(where: { $0.isTopicCompletion && $0.topicID == file.id }) {
                        Button(RecallLocalization.both("撤销完成标记", "Undo completion")) { model.undoTopicCompletion(file.id) }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }
        }.recallSurface()
    }
    private func openRequested() {
        if case .knowledge = model.destination { tab = .knowledge }
        if case .topic(let id) = model.destination { tab = .topics; selectedID = id }
    }
}

struct TopicDetailView: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let topicID: String
    let continueChat: (String) -> Void
    @State private var history = false
    @State private var adding = false
    @State private var agreement = false
    @State private var aliases = false
    @State private var source: CaptureRecord?
    @State private var correcting: MatterEvent?
    private var preferredHeight: CGFloat { min(680, 370 + CGFloat(model.state.topicReviews.first { $0.id == topicID }?.points.count ?? 0) * 60) }
    private var file: MatterFile? { model.matterFiles.first { $0.id == topicID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let file {
                let reading = TopicReading(file: file, review: model.state.topicReviews.first { $0.id == topicID })
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(file.title).font(.title2.bold())
                        Text(RecallLocalization.text(file.latest.status.manualMatterLabel)).font(.caption).foregroundStyle(RecallPalette.secondary)
                    }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(RecallLocalization.both("关闭", "Close"))
                }.padding(24)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(reading.overview).font(RecallTypography.body).textSelection(.enabled)
                        ForEach(Array(reading.points.enumerated()), id: \.offset) { _, point in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(point.title).font(.headline)
                                if point.detail != point.title { Text(point.detail).foregroundStyle(RecallPalette.secondary).textSelection(.enabled) }
                            }
                        }
                        if !reading.hasUpdatedSummary, let previous = model.state.topicReviews.first(where: { $0.id == topicID }) {
                            DisclosureGroup(RecallLocalization.both("上次整理的小结", "Previous summary")) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(previous.overview).textSelection(.enabled)
                                    ForEach(Array(previous.points.enumerated()), id: \.offset) { _, point in Text(point.detail).foregroundStyle(RecallPalette.secondary) }
                                }.padding(.top, 12)
                            }
                        }
                        if model.generatingTopicID == topicID {
                            HStack { ProgressView().controlSize(.small); Text(RecallLocalization.both("正在更新小结，已有记录仍可阅读", "Updating the summary; saved records remain available")).font(.caption); Spacer(); Button(RecallLocalization.text("停止生成")) { model.cancelTopicReview() } }
                        }
                        Menu(RecallLocalization.both("查看来源（\(file.evidenceIDs.count)）", "Sources (\(file.evidenceIDs.count))")) {
                            ForEach(file.evidenceIDs.compactMap { model.memoryWorkspace?.sources[$0] }) { value in
                                Button((value.sourceAppName ?? "记录") + " · " + value.createdAt.formatted()) { source = value }
                            }
                        }.fixedSize()
                        DisclosureGroup(RecallLocalization.both("关键记录（\(reading.records.count)）", "History (\(reading.records.count))"), isExpanded: $history) {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                ForEach(reading.records) { event in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(event.date.formatted()).font(.caption).foregroundStyle(RecallPalette.secondary)
                                        Text(event.detail).textSelection(.enabled)
                                        if let next = event.nextAction { Text(next).foregroundStyle(RecallPalette.secondary) }
                                        Button(RecallLocalization.text("更正内容")) { correcting = event }.font(.caption)
                                    }
                                    Divider()
                                }
                            }.padding(.top, 12)
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(spacing: 12) {
                    Button(RecallLocalization.both("补充进展", "Add progress")) { adding = true }
                    Menu {
                        Button(RecallLocalization.both("记住这个主题的要求", "Remember a topic instruction")) { agreement = true }
                        if model.state.memoryKnowledge.entities.contains(where: { $0.id == topicID }) { Button(RecallLocalization.text("管理别名")) { aliases = true } }
                        Button(RecallLocalization.both("整理成报告…", "Create a report…")) { model.reviewTopicToOpen = WeeklyReviewEngine.topicID(for: file); model.reviewsRequested = true; dismiss() }
                        Button(RecallLocalization.both("更新小结", "Update summary")) { model.generateTopicReview(file) }.disabled(model.generatingTopicID != nil)
                        if file.latest.status.isOpenMatter { Button(RecallLocalization.both("标记完成", "Mark complete")) { Task { await model.completeMatter(file) } } }
                        else if model.state.matterCorrections.contains(where: { $0.topicID == topicID && $0.isTopicCompletion }) { Button(RecallLocalization.both("撤销完成标记", "Undo completion")) { model.undoTopicCompletion(topicID) } }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                    Button(RecallLocalization.both("继续问", "Ask about this")) { continueChat(topicID) }.buttonStyle(.borderedProminent)
                }.padding(24)
            } else { Text(RecallLocalization.both("这个主题已移除", "This topic was removed")).padding(24); Button(RecallLocalization.both("关闭", "Close")) { dismiss() } }
        }.frame(minWidth: 580, idealWidth: 760, minHeight: 360, idealHeight: preferredHeight)
        .sheet(isPresented: $adding) { ManualMatterSheet(title: file?.title ?? "") { await model.saveManualMatter($0) } }
        .sheet(isPresented: $agreement) {
            let topic = MemoryEntity(id: topicID, name: file?.title ?? "", aliases: [], kind: "topic", sourceIDs: file?.evidenceIDs ?? [])
            MemoryAgreementEditor(claim: nil, topics: [topic], initialTopic: topic) { content, scope, scopeID, until in await model.saveMemoryAgreement(content: content, scope: scope, scopeID: scopeID, validUntil: until) }
        }
        .sheet(isPresented: $aliases) { if let entity = model.state.memoryKnowledge.entities.first(where: { $0.id == topicID }) { MemoryAliasEditor(entity: entity) { await model.saveMemoryAliases(entity: entity, text: $0) } } }
        .sheet(item: $source) { CaptureDetailSheet(capture: $0).environmentObject(model) }
        .sheet(item: $correcting) { event in MatterCorrectionSheet(event: event) { model.correctMatter($0); correcting = nil } }
    }
}

private struct MatterCorrectionHistorySheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var visibleCount = 20
    @State private var source: CaptureRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(RecallLocalization.text("更正记录")).font(.title2.bold())
                    Text(RecallLocalization.text("回看你对内容归属、状态、主题和发生时间的调整。"))
                        .foregroundStyle(RecallPalette.secondary)
                }
                Spacer()
                Button(RecallLocalization.text("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.state.matterCorrections.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(RecallPalette.accent)
                            Text(RecallLocalization.text("暂无更正记录")).font(.title3.bold())
                            Text(RecallLocalization.text("查看主题的来源时，可以更正内容。原始记录会保留，所有调整都能在这里回看。"))
                                .foregroundStyle(RecallPalette.secondary)
                        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(model.state.matterCorrections.reversed().prefix(visibleCount))) { correction in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(correction.kind.title, systemImage: "pencil.circle").font(.headline)
                                Spacer()
                                Text(correction.createdAt.formatted()).font(.caption).foregroundStyle(RecallPalette.secondary)
                            }
                            if !correction.text.isEmpty { Text(correction.text).textSelection(.enabled) }
                            if correction.kind == .eventDate, let date = correction.eventAt {
                                Text("发生时间改为 \(date.formatted())")
                            }
                            let sources = model.state.captures.filter { correction.evidenceIDs.contains($0.id) }
                            HStack {
                                Menu("查看来源（\(sources.count)）") {
                                    ForEach(sources) { capture in
                                        Button((capture.sourceAppName ?? "记录") + " · " + capture.createdAt.formatted()) { source = capture }
                                    }
                                }.disabled(sources.isEmpty)
                                Spacer()
                                Button(RecallLocalization.text("删除这条更正"), role: .destructive) { model.removeMatterCorrection(correction.id) }
                            }
                            Text(RecallLocalization.text("删除更正后，会重新使用原始记录；已完成的提醒不会自动恢复。"))
                                .font(.caption).foregroundStyle(RecallPalette.secondary)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                    if model.state.matterCorrections.count > visibleCount {
                        Button(RecallLocalization.text("再显示 20 条")) { visibleCount += 20 }
                    }
                }.padding(24)
            }.clipped()
        }.frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 640)
            .sheet(item: $source) { CaptureDetailSheet(capture: $0).environmentObject(model) }
    }
}

private struct ManualMatterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let save: (ManualMatterNote) async -> Bool
    @State private var title = ""
    @State private var detail = ""
    @State private var status: WorkEpisodeStatus = .explored
    @State private var category: ReviewCategory = .unclassified
    @State private var eventAt = Date.now
    @State private var isSaving = false
    @State private var saveError: String?
    private var note: ManualMatterNote { ManualMatterNote(title: title, detail: detail, status: status, eventAt: eventAt, reviewCategory: category) }

    init(title: String = "", save: @escaping (ManualMatterNote) async -> Bool) {
        _title = State(initialValue: title)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(RecallLocalization.text("补充记录")).font(.title2.bold())
            Text(RecallLocalization.text("记下一段进展或经历。使用已有主题名称，可以接着上次的记录。"))
                .foregroundStyle(RecallPalette.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text(RecallLocalization.text("主题名称")).font(.headline)
                TextField(RecallLocalization.text("例如：账单导出修复（3–80 字）"), text: $title).textFieldStyle(.roundedBorder)
            }
            Picker(RecallLocalization.text("回顾分类"), selection: $category) {
                ForEach(ReviewCategory.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Picker(RecallLocalization.text("当前状态"), selection: $status) {
                    ForEach([WorkEpisodeStatus.explored, .pending, .progressed, .blocked, .completed], id: \.self) {
                        Text($0.manualMatterLabel).tag($0)
                    }
                }
                DatePicker("发生时间", selection: $eventAt, in: ...Date.now)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(RecallLocalization.text("具体内容")).font(.headline)
                Text(RecallLocalization.text("记录做了什么、得到的结果，或还需要处理什么（最多 4000 字）。"))
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
                TextEditor(text: $detail).scrollContentBackground(.hidden).frame(height: 160).padding(8)
                    .background(RecallPalette.surface)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(RecallPalette.border.opacity(0.25)))
            }
            Text(RecallLocalization.text("只保存文字到本机，不会截图或自动安排通知；原始记录可在记忆时间线查看和删除。"))
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            if let saveError { Text(saveError).foregroundStyle(RecallPalette.danger).font(.callout) }
            HStack {
                Spacer()
                Button(RecallLocalization.text("取消")) { dismiss() }.disabled(isSaving)
                Button(isSaving ? "正在保存…" : "保存记录") {
                    isSaving = true
                    saveError = nil
                    let submitted = note
                    Task { @MainActor in
                        if await save(submitted) { dismiss() }
                        else { saveError = "未能保存，请重试。错误详情已记录到日志。" }
                        isSaving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(isSaving || !note.isValid)
            }
        }.padding(28).frame(width: 660).disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
    }
}

private struct MatterCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let event: MatterEvent
    let save: (MatterCorrection) -> Void
    @State private var kind: MatterCorrectionKind = .inaccurate
    @State private var text = ""
    @State private var eventDate = Date.now
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(RecallLocalization.text("更正内容")).font(.title2.bold())
            Text(event.detail).lineLimit(5).foregroundStyle(RecallPalette.secondary)
            Picker(RecallLocalization.text("如何更正"), selection: $kind) {
                ForEach(MatterCorrectionKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if kind == .separate { TextField(RecallLocalization.text("归入的主题名称"), text: $text).textFieldStyle(.roundedBorder) }
            if kind == .eventDate { DatePicker("实际发生时间", selection: $eventDate) }
            Text("更正作用于这段内容关联的 \(event.evidenceIDs.count) 条来源。原始记录保留。“不是我说的”和“结论不准确”会停止用这些来源推断；已安排的提醒只有选择“已经完成”才会关闭。")
                .font(.callout).foregroundStyle(RecallPalette.secondary)
            HStack {
                Spacer()
                Button(RecallLocalization.text("取消")) { dismiss() }
                Button(RecallLocalization.text("保存更正")) {
                    save(MatterCorrection(evidenceIDs: event.evidenceIDs, kind: kind, text: kind == .completed ? event.title : text, eventAt: kind == .eventDate ? eventDate : nil))
                }.buttonStyle(.borderedProminent)
                    .disabled(kind == .separate && text.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
            }
        }.padding(28).frame(width: 560)
    }
}
