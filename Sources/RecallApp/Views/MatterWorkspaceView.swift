import SwiftUI
import RecallKit

private enum MatterWorkspaceTab: String { case topics = "记忆主题", knowledge = "长期记忆", timeline = "时间线" }

struct MatterWorkspaceView: View {
    @EnvironmentObject private var model: RecallAppModel
    @AppStorage("recall.memory.tab") private var tab: MatterWorkspaceTab = .topics
    @State private var search = ""
    @State private var filter = 0
    @State private var showDone = false
    @State private var pendingDelete: MatterFile?
    @State private var pendingProjectFor: MatterFile?
    @State private var newProjectName = ""
    @State private var limit = 20
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
                tabButton("时间线", english: "Timeline", value: .timeline)
                tabButton("关于我", english: "About me", value: .knowledge)
                Spacer()
            }.padding(.horizontal, 24).padding(.bottom, 14)
            Divider()
            if tab == .timeline { RecordTimelineView() } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if tab == .knowledge {
                        MemoryKnowledgeView(search: "", adding: $addingMemory).environmentObject(model)
                    } else {
                        if !model.matterFiles.isEmpty {
                            HStack(spacing: 8) {
                                Picker("", selection: $filter) {
                                    Text(RecallLocalization.text("全部")).tag(0)
                                    Text(RecallLocalization.text("进行中")).tag(1)
                                    Text(RecallLocalization.text("已完成")).tag(2)
                                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                                Spacer()
                                TextField(RecallLocalization.text("搜索主题或内容"), text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            }
                        }
                        if let message = model.matterBuildMessage { Text(RecallLocalization.text(message)).font(.caption).foregroundStyle(RecallPalette.secondary) }
                        if files.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(RecallLocalization.both(search.isEmpty ? "从一件事开始" : "没有找到相关主题", search.isEmpty ? "Start with a topic" : "No matching topics")).font(.headline)
                                Text(RecallLocalization.both("保存的相关记录会串联在这里。点开主题即可回看进展、结论和来源。", "Related records appear together here. Open a topic to read its progress, conclusions and sources.")).foregroundStyle(RecallPalette.secondary)
                                if search.isEmpty { Button(RecallLocalization.text("补充记录")) { addingTitle = ""; adding = true } }
                                else { Button(RecallLocalization.text("清空搜索")) { search = ""; filter = 0 } }
                            }.recallSurface()
                        }
                        if filter == 0 && search.isEmpty {
                            let groups = TopicListPresentation.group(files, registry: model.state.topicRegistry)
                            ForEach(Array(groups.active.prefix(limit))) { file in card(file) }
                            if !groups.done.isEmpty {
                                DisclosureGroup(isExpanded: $showDone) {
                                    LazyVStack(alignment: .leading, spacing: 10) {
                                        ForEach(Array(groups.done.prefix(limit))) { file in card(file) }
                                    }.padding(.top, 8)
                                } label: {
                                    Text(RecallLocalization.both("已完成与搁置（\(groups.done.count)）", "Done and dormant (\(groups.done.count))"))
                                        .font(.subheadline).foregroundStyle(RecallPalette.secondary)
                                }
                            }
                        } else {
                            ForEach(Array(files.prefix(limit))) { file in card(file) }
                        }
                        if files.count > limit { Button(RecallLocalization.text("再显示 20 条")) { limit += 20 } }
                        if model.state.experienceHintsEnabled, let hint = model.experienceHint {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(RecallLocalization.both("以前的结果，也许能帮上忙", "A past result may help")).font(.headline)
                                Text(hint.past.detail)
                                HStack {
                                    Button(RecallLocalization.both("查看当时主题", "Open past topic")) { model.topicToOpen = model.matterFiles.first { $0.events.contains { $0.id == hint.past.id } }?.id }
                                    Button(RecallLocalization.text("不再提示这一条")) { model.dismissExperience(hint) }
                                }
                            }.recallSurface()
                        }
                    }
                }.padding(24).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }.clipped()
            }
        }
        .onAppear { openRequested() }
        .onChange(of: model.navigationRevision) { _, _ in openRequested() }
        .onChange(of: search) { _, _ in limit = 20 }
        .onChange(of: filter) { _, _ in limit = 20 }
        .sheet(isPresented: $adding) { ManualMatterSheet(title: addingTitle, status: addingTitle.isEmpty ? .explored : .progressed) { await model.saveManualMatter($0) } }
        .alert(RecallLocalization.both("新建项目", "New project"),
               isPresented: Binding(get: { pendingProjectFor != nil }, set: { if !$0 { pendingProjectFor = nil } })) {
            TextField(RecallLocalization.both("项目名称", "Project name"), text: $newProjectName)
            Button(RecallLocalization.both("取消", "Cancel"), role: .cancel) { pendingProjectFor = nil }
            Button(RecallLocalization.both("创建", "Create")) {
                let file = pendingProjectFor
                let name = newProjectName
                pendingProjectFor = nil
                Task { await model.createProject(named: name, moving: file) }
            }
        }
        .confirmationDialog(RecallLocalization.both("删除这个主题？", "Delete this topic?"),
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { file in
            Button(RecallLocalization.both("删除主题（保留原始记录）", "Delete topic (keep records)"), role: .destructive) {
                pendingDelete = nil
                Task { await model.deleteTopic(file) }
            }
        } message: { _ in
            Text(RecallLocalization.both("只移除主题、小结与完成标记，原始记录和截图不会删除。", "Only the topic, its summary and completion mark are removed. Records and screenshots are kept."))
        }
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
        let reading = TopicReading(file: file, review: model.state.topicReviews.first { $0.id == file.id })
        return Button { model.topicToOpen = file.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(file.latest.status.isOpenMatter ? RecallPalette.accent : RecallPalette.secondary.opacity(0.45))
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(RecallLocalization.text(file.latest.status.manualMatterLabel))
                    Text(file.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    if model.completingMatterIDs.contains(file.id) { Text(RecallLocalization.both("保存中…", "Saving…")).font(.caption).foregroundStyle(RecallPalette.secondary) }
                    Text(TopicListPresentation.relativeTime(file.latest.date)).font(.caption).foregroundStyle(RecallPalette.secondary)
                }
                Text(reading.headline)
                    .font(RecallTypography.body).foregroundStyle(RecallPalette.secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
        .accessibilityIdentifier("open-topic-" + file.id)
        .contextMenu {
            Button(RecallLocalization.both("继续问", "Ask about this")) { continueChat(file.id) }
            Button(RecallLocalization.both("补充进展", "Add progress")) { addingTitle = file.noteTitle; adding = true }
            if file.latest.status.isOpenMatter {
                Button(RecallLocalization.both("标记完成", "Mark complete")) { Task { await model.completeMatter(file) } }
                    .disabled(model.completingMatterIDs.contains(file.id))
            } else if model.state.matterCorrections.contains(where: { $0.isTopicCompletion && $0.topicID == file.id }) {
                Button(RecallLocalization.both("撤销完成标记", "Undo completion")) { model.undoTopicCompletion(file.id) }
            }
            Menu(RecallLocalization.both("所属项目", "Project")) {
                ForEach(model.state.topicRegistry.topics.filter(\.isProject)) { project in
                    Button(project.title) { Task { await model.assignProject("topic:" + project.id.uuidString, to: file) } }
                }
                if file.latest.date.timeIntervalSinceNow < 0, !model.state.topicRegistry.topics.filter(\.isProject).isEmpty {
                    Divider()
                    Button(RecallLocalization.both("移出项目", "Remove from project")) { Task { await model.assignProject(nil, to: file) } }
                }
                Divider()
                Button(RecallLocalization.both("新建项目…", "New project…")) { newProjectName = ""; pendingProjectFor = file }
            }
            Divider()
            Button(RecallLocalization.both("删除主题…", "Delete topic…"), role: .destructive) { pendingDelete = file }
        }
    }
    private func openRequested() {
        if case .knowledge = model.destination { tab = .knowledge; model.destination = nil }
        if case .record = model.destination { tab = .timeline }
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
    @State private var writingStep = false
    private var file: MatterFile? { model.matterFiles.first { $0.id == topicID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let file {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(file.title).font(.title2.bold()).textSelection(.enabled)
                        Text(RecallLocalization.text(file.latest.status.manualMatterLabel) + " · " + file.latest.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.callout).foregroundStyle(RecallPalette.secondary)
                    }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel(RecallLocalization.both("关闭", "Close"))
                }.padding(22)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        handoff(file)
                        if let review = model.state.topicReviews.first(where: { $0.id == topicID }) {
                            let current = TopicReading(file: file, review: review).hasUpdatedSummary
                            DisclosureGroup(current ? RecallLocalization.both("主题小结", "Topic summary") : RecallLocalization.both("上次整理的小结", "Previous summary")) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(review.overview)
                                    ForEach(Array(review.points.enumerated()), id: \.offset) { _, point in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(point.title).font(.headline)
                                            if point.detail != point.title { Text(point.detail).foregroundStyle(RecallPalette.secondary) }
                                        }
                                    }
                                }.textSelection(.enabled).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if model.generatingTopicID == topicID {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(RecallLocalization.both("正在更新小结…", "Updating summary…")).font(.caption)
                                Spacer()
                                Button(RecallLocalization.text("停止生成")) { model.cancelTopicReview() }
                            }
                        }
                        historySection(file)
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                actions(file).padding(.horizontal, 22).padding(.vertical, 14)
            } else {
                Text(RecallLocalization.both("这个主题已移除", "This topic was removed")).padding(22)
                Button(RecallLocalization.both("关闭", "Close")) { dismiss() }
            }
        }.frame(minWidth: 520, idealWidth: 660, minHeight: 400, idealHeight: 480)
        .sheet(isPresented: $writingStep) {
            if let file { TopicNextStepSheet(file: file, previous: file.resumeNextAction) }
        }
        .sheet(isPresented: $adding) {
            if let file { ManualMatterSheet(title: file.noteTitle, status: .progressed) { await model.saveManualMatter($0) } }
        }
        .sheet(isPresented: $agreement) {
            let topic = MemoryEntity(id: topicID, name: file?.title ?? "", aliases: [], kind: "topic", sourceIDs: file?.evidenceIDs ?? [])
            MemoryAgreementEditor(claim: nil, topics: [topic], initialTopic: topic) { content, scope, scopeID, until in await model.saveMemoryAgreement(content: content, scope: scope, scopeID: scopeID, validUntil: until) }
        }
        .sheet(isPresented: $aliases) { if let entity = model.state.memoryKnowledge.entities.first(where: { $0.id == topicID }) { MemoryAliasEditor(entity: entity) { await model.saveMemoryAliases(entity: entity, text: $0) } } }
        .sheet(item: $source) { CaptureDetailSheet(capture: $0).environmentObject(model) }
        .sheet(item: $correcting) { event in MatterCorrectionSheet(event: event) { model.correctMatter($0); correcting = nil } }
    }
    @ViewBuilder private func handoff(_ file: MatterFile) -> some View {
        let handoff = TopicHandoff(file: file)
        let next = handoff.nextStep
        if let headline = handoff.progress {
            VStack(alignment: .leading, spacing: 5) {
                Text(RecallLocalization.both("上次进展", "Last update"))
                    .font(.caption.weight(.semibold)).foregroundStyle(RecallPalette.secondary)
                Text(headline).font(RecallTypography.title).textSelection(.enabled)
                if let date = handoff.progressDate, !Calendar.current.isDate(date, inSameDayAs: file.latest.date) {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(RecallPalette.secondary)
                }
            }
        }
        if file.latest.status.isOpenMatter {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(RecallLocalization.both("下一步", "Next step"), systemImage: "arrow.turn.down.right")
                        .font(.headline).foregroundStyle(RecallPalette.accent)
                    Spacer()
                    Button(next == nil ? RecallLocalization.both("留一句", "Write a step") : RecallLocalization.both("改写下一步", "Revise step")) {
                        writingStep = true
                    }.buttonStyle(.link)
                }
                if let next { Text(next).font(RecallTypography.body).textSelection(.enabled) }
                else { Text(RecallLocalization.both("还没记下从哪里继续。", "No next step recorded yet.")).foregroundStyle(RecallPalette.secondary) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func historySection(_ file: MatterFile) -> some View {
        DisclosureGroup(RecallLocalization.both("进展记录（\(file.events.count)）", "History (\(file.events.count))"), isExpanded: $history) {
            if history {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(file.events.reversed()) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.date.formatted() + " · " + RecallLocalization.text(event.status.manualMatterLabel))
                                .font(.caption).foregroundStyle(RecallPalette.secondary)
                            Text(event.detail).textSelection(.enabled)
                            if let next = event.nextAction, next != event.detail && next != event.headline {
                                Text(RecallLocalization.both("下一步 · ", "Next step · ") + next).foregroundStyle(RecallPalette.secondary)
                            }
                            HStack(spacing: 14) {
                                let sources = event.evidenceIDs.compactMap { model.memoryWorkspace?.sources[$0] }
                                if sources.count == 1, let only = sources.first {
                                    Button(RecallLocalization.text("查看来源")) { source = only }
                                } else if !sources.isEmpty {
                                    Menu(RecallLocalization.both("查看来源（\(sources.count)）", "Sources (\(sources.count))")) {
                                        ForEach(sources) { record in
                                            Button((record.sourceAppName ?? RecallLocalization.both("记录", "Record")) + " · " + record.createdAt.formatted()) { source = record }
                                        }
                                    }.menuStyle(.borderlessButton).fixedSize()
                                }
                                Button(RecallLocalization.text("更正内容")) { correcting = event }
                            }.buttonStyle(.link).font(.caption)
                        }
                        Divider()
                    }
                }.padding(.top, 10)
            }
        }
    }

    private func actions(_ file: MatterFile) -> some View {
        HStack(spacing: 12) {
            Button(RecallLocalization.both("记进展", "Add progress")) { adding = true }.buttonStyle(.borderedProminent)
            Button(RecallLocalization.both("继续问", "Ask about this")) { continueChat(topicID) }
            Menu {
                Button(RecallLocalization.both("更新小结", "Update summary")) { model.generateTopicReview(file) }.disabled(model.generatingTopicID != nil)
                Button(RecallLocalization.both("整理成报告…", "Create a report…")) { model.reviewTopicToOpen = WeeklyReviewEngine.topicID(for: file); model.reviewsRequested = true; dismiss() }
                Divider()
                Button(RecallLocalization.both("记住这个主题的要求", "Remember a topic instruction")) { agreement = true }
                if model.state.memoryKnowledge.entities.contains(where: { $0.id == topicID }) {
                    Button(RecallLocalization.text("管理别名")) { aliases = true }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(RecallLocalization.both("更多主题操作", "More topic actions"))
            Spacer()
            if file.latest.status.isOpenMatter {
                Button(model.completingMatterIDs.contains(file.id) ? RecallLocalization.both("保存中…", "Saving…") : RecallLocalization.both("标记完成", "Mark complete")) {
                    Task { await model.completeMatter(file) }
                }.disabled(model.completingMatterIDs.contains(file.id))
            } else if model.state.matterCorrections.contains(where: { $0.isTopicCompletion && model.state.canonicalTopicID($0.topicID ?? "") == topicID }) {
                Button(RecallLocalization.both("撤销完成", "Undo completion")) { model.undoTopicCompletion(topicID) }
            }
        }
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

    init(title: String = "", status: WorkEpisodeStatus = .explored, save: @escaping (ManualMatterNote) async -> Bool) {
        _title = State(initialValue: title)
        _status = State(initialValue: status)
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
