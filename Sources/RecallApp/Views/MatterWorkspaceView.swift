import SwiftUI
import RecallKit

private enum MatterWorkspaceTab: String, CaseIterable {
    case inProgress = "进行中"
    case allTopics = "全部主题"
    case weeklyReview = "一周回顾"
    case knowledge = "记忆与约定"
}

/// Topic-based memory browsing, with a fixed header outside the clipped scroll view.
struct MatterWorkspaceView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var tab: MatterWorkspaceTab = .inProgress
    @State private var search = ""
    @State private var visibleCount = 20
    @State private var olderVisibleCount = 20
    @State private var showsOlderMatters = false
    @State private var selected: MatterFile?
    @State private var source: CaptureRecord?
    @State private var correctionEvent: MatterEvent?
    @State private var showsNewMatter = false
    @State private var newMatterTitle = ""
    @State private var showsCorrections = false
    let continueChat: (String) -> Void

    private var files: [MatterFile] {
        model.matterFiles.filter { search.isEmpty || ($0.title + $0.events.map(\.detail).joined(separator: " ")).localizedCaseInsensitiveContains(search) }
    }
    private var resumeFiles: [MatterFile] { files.filter { $0.latest.status.isOpenMatter } }
    private var recentResumeFiles: [MatterFile] { resumeFiles.filter { !$0.needsStatusUpdate() } }
    private var olderResumeFiles: [MatterFile] { resumeFiles.filter { $0.needsStatusUpdate() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    pageIntroduction
                    Spacer(minLength: 16)
                    pageActions
                }
                VStack(alignment: .leading, spacing: 20) {
                    pageIntroduction
                    pageActions
                }
            }.padding(24)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    browsingTabs
                    Spacer(minLength: 16)
                    if tab != .weeklyReview { topicSearch }
                }
                VStack(alignment: .leading, spacing: 14) {
                    browsingTabs
                    if tab != .weeklyReview { topicSearch }
                }
            }.padding(.horizontal, 24).padding(.bottom, 18)
            Divider()
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if tab != .weeklyReview, let message = model.matterBuildMessage {
                        Label(message, systemImage: "info.circle")
                            .foregroundStyle(.secondary).padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if tab == .inProgress {
                        if resumeFiles.isEmpty {
                            empty(search.isEmpty ? (model.matterFiles.isEmpty ? "还没有整理出主题" : "暂时没有进行中的主题") : "没有找到匹配的进行中主题",
                                detail: search.isEmpty ? (model.matterFiles.isEmpty ? "保存记录后，Recall 会把同一件事的相关内容串联起来。你也可以补充一条记录，从这里开始。" : "已完成或仅作记录的内容，可以在‘全部主题’中回看。") : "换个关键词，或清空搜索后查看。")
                        }
                        ForEach(Array(recentResumeFiles.prefix(visibleCount))) { file in
                            fileCard(file, resume: true)
                        }
                        more(total: recentResumeFiles.count)
                        if !olderResumeFiles.isEmpty {
                            DisclosureGroup(isExpanded: $showsOlderMatters) {
                                VStack(alignment: .leading, spacing: 18) {
                                    Text("这些主题超过两周没有新的进展记录，当前状态待更新。你可以回看来源，或补充最近的进展。")
                                        .foregroundStyle(.secondary)
                                    ForEach(Array(olderResumeFiles.prefix(olderVisibleCount))) { file in
                                        fileCard(file, resume: true)
                                    }
                                    if olderResumeFiles.count > olderVisibleCount {
                                        Button("再显示 20 条") { olderVisibleCount += 20 }
                                    }
                                }.padding(.top, 16)
                            } label: {
                                Label("较早的记录 · \(olderResumeFiles.count) 个主题待更新", systemImage: "clock")
                                    .font(.headline).foregroundStyle(.secondary)
                            }.padding(20)
                                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 18))
                        }
                        if model.state.experienceHintsEnabled, let hint = model.experienceHint,
                           resumeFiles.contains(where: { $0.id == hint.currentID }) {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("以前的结果，也许能帮上忙", systemImage: "sparkles").font(.headline).foregroundStyle(.purple)
                                Text(hint.past.detail).textSelection(.enabled)
                                Text("相关主题：\(hint.matchingTerms.joined(separator: "、"))。当时的条件可能不同，请先查看来源。")
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("查看当时记录") { source = model.state.captures.first { hint.past.evidenceIDs.contains($0.id) } }
                                    Button("不再提示这一条") { model.dismissExperience(hint.id) }
                                }
                            }.padding(20).background(.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                        }
                    } else if tab == .allTopics {
                        if files.isEmpty {
                            empty(search.isEmpty ? "还没有整理出主题" : "没有找到匹配的主题",
                                detail: search.isEmpty ? "保存记录后，Recall 会把同一件事的相关内容串联起来。你也可以补充一条记录，从这里开始。" : "换个关键词，或清空搜索后查看全部主题。")
                        }
                        ForEach(Array(files.prefix(visibleCount))) { file in fileCard(file, resume: false) }
                        more(total: files.count)
                    } else if tab == .knowledge {
                        MemoryKnowledgeView(search: search).environmentObject(model)
                    } else if tab == .weeklyReview {
                        WeeklyReviewView(scrollToReport: { withAnimation { proxy.scrollTo("weekly-report", anchor: .top) } }).environmentObject(model)
                    }
                }.padding(24).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }.clipped()
            }
        }
        .onAppear { if model.weeklyReportToOpen != nil { tab = .weeklyReview } }
        .onChange(of: model.weeklyReportToOpen) { _, id in if id != nil { tab = .weeklyReview } }
        .onChange(of: tab) { _, _ in visibleCount = 20; olderVisibleCount = 20 }
        .onChange(of: search) { _, text in
            visibleCount = 20
            olderVisibleCount = 20
            showsOlderMatters = !text.isEmpty
        }
        .sheet(isPresented: $showsNewMatter) {
            ManualMatterSheet(title: newMatterTitle) { note in
                guard await model.saveManualMatter(note) else { return false }
                search = ""
                tab = .allTopics
                return true
            }
        }
        .sheet(isPresented: $showsCorrections) {
            MatterCorrectionHistorySheet().environmentObject(model)
        }
        .sheet(item: $selected) { file in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(file.title).font(.title2.bold())
                        Text("沿着记录回看这件事的进展与来由。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("完成") { selected = nil }
                }.padding(24)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(file.events.reversed()) { event in
                            VStack(alignment: .leading, spacing: 10) {
                                Text((event.eventAt == nil ? "记录于 " : "发生于 ") + event.date.formatted())
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(event.detail).textSelection(.enabled)
                                if let action = event.nextAction {
                                    Text("记录中的后续行动").font(.caption).foregroundStyle(.secondary)
                                    Text(action).textSelection(.enabled)
                                }
                                HStack {
                                    Menu("查看来源（\(event.evidenceIDs.count)）") {
                                        ForEach(model.state.captures.filter { event.evidenceIDs.contains($0.id) }) { capture in
                                            Button((capture.sourceAppName ?? "记录") + " · " + capture.createdAt.formatted()) { source = capture }
                                        }
                                    }
                                    Button("更正内容") { correctionEvent = event }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }.padding(24)
                }
                Button("围绕这件事继续问") {
                    selected = nil
                    continueChat("关于\(file.title)，上次进展是什么？有哪些已确认的结论和仍未知的信息？")
                }.buttonStyle(.borderedProminent).padding(24)
            }.frame(minWidth: 650, idealWidth: 820, minHeight: 500, idealHeight: 720)
                .sheet(item: $source) { CaptureDetailSheet(capture: $0).environmentObject(model) }
                .sheet(item: $correctionEvent) { event in
                    MatterCorrectionSheet(event: event) { correction in
                        model.correctMatter(correction)
                        correctionEvent = nil
                        selected = nil
                    }
                }
        }
        .sheet(item: Binding(get: { selected == nil ? source : nil }, set: { source = $0 })) {
            CaptureDetailSheet(capture: $0).environmentObject(model)
        }
    }

    private var pageIntroduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("记忆脉络").font(.largeTitle.bold())
            Text("把零散的记录，串成可以接续的经历。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(minWidth: 300, alignment: .leading)
    }

    private var pageActions: some View {
        HStack(spacing: 12) {
            if model.isBuildingMatters { ProgressView().controlSize(.small).help("正在整理记录") }
            Button { model.organizeExistingMatters() } label: {
                Label("整理已有记录", systemImage: "arrow.clockwise")
            }.disabled(model.isBuildingMatters)
                .help("在本地重新整理已保存的记录")
            Button { supplement() } label: {
                Label("补充记录", systemImage: "plus")
            }.buttonStyle(.borderedProminent)
            Menu {
                Button { showsCorrections = true } label: {
                    Label("更正记录", systemImage: "clock.arrow.circlepath")
                }
                Divider()
                Toggle("显示历史经验提示", isOn: Binding(get: { model.state.experienceHintsEnabled }, set: { model.setExperienceHints($0) }))
            } label: {
                Image(systemName: "ellipsis.circle")
            }.menuStyle(.borderlessButton)
                .fixedSize().accessibilityLabel("更多选项").help("更多选项")
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var browsingTabs: some View {
        Picker("浏览记忆脉络", selection: $tab) {
            ForEach(MatterWorkspaceTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden()
            .frame(minWidth: 440, maxWidth: 580)
            .accessibilityLabel("浏览记忆脉络")
    }

    private var topicSearch: some View {
        TextField("搜索主题或内容", text: $search).textFieldStyle(.roundedBorder)
            .frame(minWidth: 200, maxWidth: 260)
            .accessibilityLabel("搜索主题或内容")
    }

    private func fileCard(_ file: MatterFile, resume: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(file.title).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(file.needsStatusUpdate() ? "状态待更新" : file.latest.status.matterLabel)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if resume {
                VStack(alignment: .leading, spacing: 6) {
                    Text((file.resumeProgress.status == .pending && file.resumeNextAction == nil ? "待处理事项" : "上次进展")
                        + " · " + file.resumeProgress.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(file.resumeText).textSelection(.enabled)
                }
                if let action = file.resumeNextAction {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("记录中的后续行动").font(.caption).foregroundStyle(.secondary)
                        Text(action).textSelection(.enabled)
                    }
                }
            } else {
                Text(file.latest.detail).textSelection(.enabled)
                if let action = file.latest.nextAction {
                    Text(action).textSelection(.enabled)
                }
            }
            if file.needsStatusUpdate() {
                Text("此后暂无新的进展记录，当前状态仍待确认。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("最近记录于 \(file.latest.date.formatted(date: .abbreviated, time: .omitted)) · \(file.evidenceIDs.count) 条来源")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("查看脉络与来源") { selected = file }
                if resume {
                    Button("补充进展") { supplement(title: file.title) }
                    Button("接着问") { continueChat("关于\(file.title)，请找回上次的进展、已确认的结论和仍缺少的信息。") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 18))
    }
    private func empty(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(.blue)
            Text(title).font(.title2.bold())
            Text(detail).foregroundStyle(.secondary)
            if model.isBuildingMatters {
                Text("正在检查已保存的记录…").font(.callout).foregroundStyle(.secondary)
            } else if !search.isEmpty {
                Button("清空搜索") { search = "" }
            } else {
                HStack {
                    Button("补充记录") { supplement() }.buttonStyle(.borderedProminent)
                    Button("整理已有记录") { model.organizeExistingMatters() }
                    if !model.matterFiles.isEmpty && tab != .allTopics {
                        Button("查看全部主题") { tab = .allTopics }
                    }
                }
            }
        }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func supplement(title: String = "") {
        newMatterTitle = title
        showsNewMatter = true
    }
    @ViewBuilder private func more(total: Int) -> some View {
        if total > visibleCount { Button("再显示 20 条") { visibleCount += 20 } }
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
                    Text("更正记录").font(.title2.bold())
                    Text("回看你对内容归属、状态、主题和发生时间的调整。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.state.matterCorrections.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.blue)
                            Text("暂无更正记录").font(.title3.bold())
                            Text("查看主题的来源时，可以更正内容。原始记录会保留，所有调整都能在这里回看。")
                                .foregroundStyle(.secondary)
                        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(model.state.matterCorrections.reversed().prefix(visibleCount))) { correction in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(correction.kind.title, systemImage: "pencil.circle").font(.headline)
                                Spacer()
                                Text(correction.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
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
                                Button("删除这条更正", role: .destructive) { model.removeMatterCorrection(correction.id) }
                            }
                            Text("删除更正后，会重新使用原始记录；已完成的提醒不会自动恢复。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
                    }
                    if model.state.matterCorrections.count > visibleCount {
                        Button("再显示 20 条") { visibleCount += 20 }
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
            Text("补充记录").font(.title2.bold())
            Text("记下一段进展或经历。使用已有主题名称，可以接着上次的记录。")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("主题名称").font(.headline)
                TextField("例如：账单导出修复（3–80 字）", text: $title).textFieldStyle(.roundedBorder)
            }
            Picker("回顾分类", selection: $category) {
                ForEach(ReviewCategory.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Picker("当前状态", selection: $status) {
                    ForEach([WorkEpisodeStatus.explored, .pending, .progressed, .blocked, .completed], id: \.self) {
                        Text($0.manualMatterLabel).tag($0)
                    }
                }
                DatePicker("发生时间", selection: $eventAt, in: ...Date.now)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("具体内容").font(.headline)
                Text("记录做了什么、得到的结果，或还需要处理什么（最多 4000 字）。")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $detail).frame(height: 160).padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.25)))
            }
            Text("只保存文字到本机，不会截图或自动安排通知；原始记录可在记忆时间线查看和删除。")
                .font(.caption).foregroundStyle(.secondary)
            if let saveError { Text(saveError).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.disabled(isSaving)
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
            Text("更正内容").font(.title2.bold())
            Text(event.detail).lineLimit(5).foregroundStyle(.secondary)
            Picker("如何更正", selection: $kind) {
                ForEach(MatterCorrectionKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if kind == .separate { TextField("归入的主题名称", text: $text).textFieldStyle(.roundedBorder) }
            if kind == .eventDate { DatePicker("实际发生时间", selection: $eventDate) }
            Text("更正作用于这段内容关联的 \(event.evidenceIDs.count) 条来源。原始记录保留。“不是我说的”和“结论不准确”会停止用这些来源推断；已安排的提醒只有选择“已经完成”才会关闭。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存更正") {
                    save(MatterCorrection(evidenceIDs: event.evidenceIDs, kind: kind, text: kind == .completed ? event.title : text, eventAt: kind == .eventDate ? eventDate : nil))
                }.buttonStyle(.borderedProminent)
                    .disabled(kind == .separate && text.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
            }
        }.padding(28).frame(width: 560)
    }
}
