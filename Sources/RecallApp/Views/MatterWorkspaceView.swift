import SwiftUI
import RecallKit

private func t(_ chinese: String, _ english: String) -> String { RecallLocalization.both(chinese, english) }

private enum MatterWorkspaceTab: String { case topics = "记忆主题", knowledge = "长期记忆", timeline = "时间线" }

private enum TopicListFilter: Int, CaseIterable {
    case all = 0, active = 1, dormant = 2, completed = 3
}

struct MatterWorkspaceView: View {
    @EnvironmentObject private var model: RecallAppModel
    @AppStorage("recall.memory.tab") private var tab: MatterWorkspaceTab = .topics
    @State private var search = ""
    @State private var filter: TopicListFilter = .all
    @State private var showDormant = false
    @State private var showDone = false
    @State private var collapsedProjectIDs: Set<UUID> = []
    @State private var selectedTopicID: String?
    @State private var pendingDelete: MatterFile?
    @State private var pendingProjectDelete: Topic?
    @State private var pendingProjectFor: MatterFile?
    @State private var creatingStandaloneProject = false
    @State private var newProjectName = ""
    @State private var limit = 30
    @State private var quickProgressDraft: QuickProgressDraft?
    @State private var addingHistorical = false
    @State private var addingMemory = false
    @State private var merging = false
    @State private var corrections = false
    @State private var references = false
    let continueChat: (String) -> Void

    private func matchesSearch(_ file: MatterFile) -> Bool {
        guard !search.isEmpty else { return true }
        let aliases = model.state.topicRegistry.resolvedTopic(for: file)?.aliases.joined(separator: " ") ?? ""
        let haystack = file.title + " " + aliases + " " + file.events.map(\.detail).joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(search)
    }

    private var searchedFiles: [MatterFile] {
        model.matterFiles.filter(matchesSearch)
    }

    private var lifecycleSections: (active: [MatterFile], dormant: [MatterFile], done: [MatterFile]) {
        TopicListPresentation.sections(searchedFiles, registry: model.state.topicRegistry)
    }

    private var filteredFiles: [MatterFile] {
        let split = lifecycleSections
        switch filter {
        case .all:
            return split.active + split.dormant + split.done
        case .active:
            return split.active
        case .dormant:
            return split.dormant
        case .completed:
            return split.done
        }
    }

    private var effectiveSelectedID: String? {
        if let selectedTopicID, filteredFiles.contains(where: { $0.id == selectedTopicID }) {
            return selectedTopicID
        }
        if let selectedTopicID, model.matterFiles.contains(where: { $0.id == selectedTopicID }) {
            return selectedTopicID
        }
        return lifecycleSections.active.first?.id ?? filteredFiles.first?.id
    }

    private var recentTopicTitles: [String] {
        Array(lifecycleSections.active.map(\.title).prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecallPageHeader(
                title: t("记忆", "Memory"),
                subtitle: t("找回一件事的经过，让 Recall 更了解你", "Trace how things unfolded and help Recall understand you")
            ) {
                if tab == .topics {
                    HStack(spacing: 10) {
                        Button {
                            quickProgressDraft = QuickProgressDraft(topicTitle: "", lockedTopic: false)
                        } label: {
                            Label(t("记下进展", "Log progress"), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)

                        Menu {
                            Button(t("新建项目分组…", "New project group…")) {
                                newProjectName = ""
                                creatingStandaloneProject = true
                            }
                            Button(RecallLocalization.text("合并主题")) { merging = true }
                            Button(t("补记历史时间的记录…", "Backdate a record…")) { addingHistorical = true }
                            Divider()
                            Button(RecallLocalization.text("资料与线索")) { references = true }
                            Button(RecallLocalization.text("更正记录")) { corrections = true }
                            Button(RecallLocalization.text("更新记忆")) { model.organizeMemoryNow() }
                                .disabled(model.isBuildingMatters || model.isOrganizingMemory)
                            Divider()
                            Toggle(RecallLocalization.text("显示历史经验提示"), isOn: Binding(
                                get: { model.state.experienceHintsEnabled },
                                set: { model.setExperienceHints($0) }
                            ))
                        } label: {
                            HStack(spacing: 4) {
                                Text(t("整理", "Manage"))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.bordered)
                        .fixedSize()
                    }
                }
            }
            HStack(spacing: 28) {
                tabButton("主题", english: "Topics", value: .topics)
                tabButton("时间线", english: "Timeline", value: .timeline)
                tabButton("关于我", english: "About me", value: .knowledge)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            Divider()

            switch tab {
            case .timeline:
                RecordTimelineView()
            case .knowledge:
                ScrollView {
                    MemoryKnowledgeView(search: "", adding: $addingMemory)
                        .environmentObject(model)
                        .padding(24)
                        .frame(maxWidth: 1100)
                        .frame(maxWidth: .infinity)
                }
                .clipped()
            case .topics:
                topicsWorkspace
            }
        }
        .onAppear { syncSelectionAndDestination() }
        .onChange(of: model.navigationRevision) { _, _ in syncSelectionAndDestination() }
        .onChange(of: model.selectedWorkspaceTopicID) { _, id in
            if let id {
                tab = .topics
                selectedTopicID = id
                model.selectedWorkspaceTopicID = nil
            }
        }
        .onChange(of: search) { _, _ in limit = 30 }
        .onChange(of: filter) { _, _ in limit = 30 }
        .sheet(item: $quickProgressDraft) { draft in
            QuickProgressSheet(
                draft: draft,
                recentTopics: recentTopicTitles,
                onOpenHistoricalForm: { addingHistorical = true }
            ) { note in
                await model.saveManualMatter(note)
            }
        }
        .sheet(isPresented: $addingHistorical) {
            ManualMatterSheet { await model.saveManualMatter($0) }
        }
        .alert(t("新建项目分组", "New project"),
               isPresented: Binding(
                get: { pendingProjectFor != nil || creatingStandaloneProject },
                set: { if !$0 { pendingProjectFor = nil; creatingStandaloneProject = false } }
               )) {
            TextField(t("项目名称", "Project name"), text: $newProjectName)
            Button(t("取消", "Cancel"), role: .cancel) {
                pendingProjectFor = nil
                creatingStandaloneProject = false
            }
            Button(t("创建", "Create")) {
                let file = pendingProjectFor
                let name = newProjectName
                pendingProjectFor = nil
                creatingStandaloneProject = false
                Task { await model.createProject(named: name, moving: file) }
            }
        }
        .confirmationDialog(t("解散这个项目分组？", "Remove this project group?"),
                            isPresented: Binding(get: { pendingProjectDelete != nil }, set: { if !$0 { pendingProjectDelete = nil } }),
                            presenting: pendingProjectDelete) { project in
            Button(t("解散项目（保留旗下主题）", "Remove project (keep topics)"), role: .destructive) {
                pendingProjectDelete = nil
                Task { await model.deleteProject(project) }
            }
        } message: { _ in
            Text(t("旗下的主题会回到未分组列表，任何记录都不会删除。", "Topics inside will return to the top level. No records are deleted."))
        }
        .confirmationDialog(t("删除这个主题？", "Delete this topic?"),
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { file in
            Button(t("删除主题（保留原始记录）", "Delete topic (keep records)"), role: .destructive) {
                if selectedTopicID == file.id { selectedTopicID = nil }
                pendingDelete = nil
                Task { await model.deleteTopic(file) }
            }
        } message: { _ in
            Text(t("只移除主题、小结与完成标记，原始记录和截图不会删除。", "Only the topic, its summary and completion mark are removed. Records and screenshots are kept."))
        }
        .sheet(isPresented: $merging) { TopicMergeSheet().environmentObject(model) }
        .sheet(isPresented: $references) { MemoryReferenceBrowser().environmentObject(model) }
        .sheet(isPresented: $corrections) { MatterCorrectionHistorySheet().environmentObject(model) }
    }

    // MARK: - Topics Split / Adaptive Workspace

    private var topicsWorkspace: some View {
        GeometryReader { viewport in
            let splitMode = viewport.size.width >= 840 && !model.matterFiles.isEmpty
            if splitMode {
                let masterWidth = min(400, max(330, floor(viewport.size.width * 0.36)))
                HStack(spacing: 0) {
                    topicsMasterPane(splitMode: true)
                        .frame(width: masterWidth, height: viewport.size.height, alignment: .topLeading)
                    Rectangle()
                        .fill(RecallPalette.border)
                        .frame(width: 1, height: viewport.size.height)
                    Group {
                        if let activeID = effectiveSelectedID {
                            TopicDetailContentView(
                                topicID: activeID,
                                embedded: true,
                                requestNewProject: { file in
                                    newProjectName = ""
                                    pendingProjectFor = file
                                },
                                requestDeleteTopic: { file in
                                    pendingDelete = file
                                },
                                onAsk: { id, question in
                                    if let question {
                                        model.openTopicConversation(id, question: question)
                                    } else {
                                        model.openTopicConversation(id)
                                    }
                                }
                            )
                            .id(activeID)
                        } else {
                            emptyDetailPlaceholder
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(RecallPalette.background)
                }
            } else {
                ScrollView {
                    topicsListBody(splitMode: false)
                        .padding(24)
                        .frame(maxWidth: 960)
                        .frame(maxWidth: .infinity)
                }
                .clipped()
            }
        }
    }

    private func topicsMasterPane(splitMode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                TextField(t("搜索主题、进展或曾用名", "Search topics, progress or aliases"), text: $search)
                    .textFieldStyle(.roundedBorder)
                filterChipsRow
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)

            if let message = model.matterBuildMessage {
                Text(RecallLocalization.text(message))
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
                    .padding(.horizontal, 16)
            }

            ScrollView {
                topicsListBody(splitMode: splitMode)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
            }
            .clipped()
        }
        .background(RecallPalette.background)
    }

    private var filterChipsRow: some View {
        let split = lifecycleSections
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(t("全部", "All"), value: .all)
                filterChip(t("推进中 \(split.active.count)", "In progress \(split.active.count)"), value: .active)
                if !split.dormant.isEmpty || filter == .dormant {
                    filterChip(t("已搁置 \(split.dormant.count)", "Shelved \(split.dormant.count)"), value: .dormant)
                }
                filterChip(t("已做完 \(split.done.count)", "Done \(split.done.count)"), value: .completed)
            }
        }
    }

    private func filterChip(_ title: String, value: TopicListFilter) -> some View {
        Button { filter = value } label: {
            Text(title)
                .font(.system(size: 12, weight: filter == value ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(filter == value ? RecallPalette.accent : RecallPalette.secondary)
                .background(filter == value ? RecallPalette.selected : RecallPalette.border.opacity(0.28), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == value ? .isSelected : [])
    }

    @ViewBuilder
    private func topicsListBody(splitMode: Bool) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if !splitMode && !model.matterFiles.isEmpty {
                HStack(spacing: 10) {
                    filterChipsRow
                    Spacer(minLength: 8)
                    TextField(t("搜索主题或内容", "Search topics"), text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
                .padding(.bottom, 4)
                if let message = model.matterBuildMessage {
                    Text(RecallLocalization.text(message))
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                }
            }

            if filteredFiles.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(t(model.matterFiles.isEmpty ? "从一件事开始" : "没有匹配的主题",
                           model.matterFiles.isEmpty ? "Start with a topic" : "No matching topics"))
                        .font(.headline)
                    Text(t(model.matterFiles.isEmpty
                           ? "保存的相关记录会串联在这里。点开主题即可十秒看清停在哪、还差什么。"
                           : "可以切换筛选状态或清空搜索词查看其他主题。",
                           model.matterFiles.isEmpty
                           ? "Related records appear together here. Open a topic to see where it stands and what remains."
                           : "Try switching status filters or clearing your search query."))
                        .font(.callout)
                        .foregroundStyle(RecallPalette.secondary)
                    if model.matterFiles.isEmpty {
                        Button(t("记下进展", "Log progress")) {
                            quickProgressDraft = QuickProgressDraft(topicTitle: "", lockedTopic: false)
                        }
                    } else {
                        Button(t("重置筛选", "Reset filters")) { search = ""; filter = .all }
                            .buttonStyle(.plain)
                            .foregroundStyle(RecallPalette.accent)
                    }
                }
                .recallSurface()
            } else if filter == .all && search.isEmpty {
                let split = lifecycleSections
                if !split.active.isEmpty {
                    groupedActiveList(Array(split.active.prefix(limit)), splitMode: splitMode)
                } else {
                    Text(t("当前没有推进中的主题。", "No active topics right now."))
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                        .padding(.vertical, 6)
                }

                if !split.dormant.isEmpty {
                    DisclosureGroup(isExpanded: $showDormant) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(split.dormant.prefix(limit))) { file in
                                card(file, splitMode: splitMode)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text(t("已搁置（\(split.dormant.count)）", "Shelved (\(split.dormant.count))"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(RecallPalette.secondary)
                    }
                    .padding(.top, 6)
                }

                if !split.done.isEmpty {
                    DisclosureGroup(isExpanded: $showDone) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(split.done.prefix(limit))) { file in
                                card(file, splitMode: splitMode)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text(t("已做完（\(split.done.count)）", "Done (\(split.done.count))"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(RecallPalette.secondary)
                    }
                    .padding(.top, 4)
                }
            } else {
                groupedActiveList(Array(filteredFiles.prefix(limit)), splitMode: splitMode)
            }

            if filteredFiles.count > limit {
                Button(RecallLocalization.text("再显示 20 条")) { limit += 20 }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(RecallPalette.accent)
                    .padding(.top, 4)
            }

            if model.state.experienceHintsEnabled, let hint = model.experienceHint {
                VStack(alignment: .leading, spacing: 8) {
                    Label(t("以前的结果，也许能帮上忙", "A past result may help"), systemImage: "lightbulb")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RecallPalette.accent)
                    Text(hint.past.detail)
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                        .lineLimit(3)
                    HStack(spacing: 12) {
                        Button(t("查看当时主题", "Open past topic")) {
                            if let target = model.matterFiles.first(where: { $0.events.contains { $0.id == hint.past.id } })?.id {
                                if splitMode { selectedTopicID = target } else { model.topicToOpen = target }
                            }
                        }
                        .font(.caption.weight(.medium))
                        Button(RecallLocalization.text("不再提示这一条")) { model.dismissExperience(hint) }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(RecallPalette.secondary)
                    }
                }
                .recallSurface(padding: 14)
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func groupedActiveList(_ items: [MatterFile], splitMode: Bool) -> some View {
        let hasProjects = model.state.topicRegistry.topics.contains(where: \.isProject)
        let groups = TopicListPresentation.groupedByProject(items, registry: model.state.topicRegistry)
        if !hasProjects || (groups.count == 1 && groups[0].project == nil) {
            ForEach(items) { file in
                card(file, splitMode: splitMode)
            }
        } else {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                if let project = group.project {
                    let isCollapsed = collapsedProjectIDs.contains(project.id)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Button {
                                if isCollapsed { collapsedProjectIDs.remove(project.id) }
                                else { collapsedProjectIDs.insert(project.id) }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 10, weight: .bold))
                                    Image(systemName: "folder")
                                        .font(.caption)
                                    Text(project.title)
                                        .font(.caption.weight(.semibold))
                                    Text("\(group.files.count)")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(RecallPalette.border.opacity(0.5), in: Capsule())
                                }
                                .foregroundStyle(RecallPalette.secondary)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Menu {
                                Button(t("解散项目分组…", "Remove project group…"), role: .destructive) {
                                    pendingProjectDelete = project
                                }
                            } label: {
                                Text(t("整理", "Manage"))
                                    .font(.caption)
                                    .foregroundStyle(RecallPalette.secondary)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 4)

                        if !isCollapsed {
                            ForEach(group.files) { file in
                                card(file, splitMode: splitMode)
                            }
                        }
                    }
                } else {
                    if groups.count > 1 {
                        Text(t("未归组主题", "Ungrouped"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RecallPalette.secondary)
                            .padding(.horizontal, 4)
                            .padding(.top, 6)
                    }
                    ForEach(group.files) { file in
                        card(file, splitMode: splitMode)
                    }
                }
            }
        }
    }

    private var emptyDetailPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(RecallPalette.accent)
            Text(t("选择一个主题查看现在与经过", "Select a topic to see where it stands"))
                .font(.headline)
            Text(t("左侧点选任意主题，十秒看清最后确认停在哪、经过如何，并顺手往下推。", "Choose any topic on the left to inspect its status, timeline, and next actions."))
                .font(.callout)
                .foregroundStyle(RecallPalette.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tabButton(_ title: String, english: String, value: MatterWorkspaceTab) -> some View {
        Button { tab = value } label: {
            Text(RecallLocalization.both(title, english))
                .font(.headline)
                .foregroundStyle(tab == value ? RecallPalette.accent : RecallPalette.secondary)
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) {
                    if tab == value { Rectangle().fill(RecallPalette.accent).frame(height: 2) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    private func card(_ file: MatterFile, splitMode: Bool) -> some View {
        let reading = TopicReading(file: file, review: model.state.topicReviews.first { $0.id == file.id })
        let lifecycle = TopicListPresentation.lifecycle(for: file, registry: model.state.topicRegistry)
        let isSelected = splitMode && effectiveSelectedID == file.id
        let isBlocked = lifecycle == .active && file.latest.status == .blocked
        let isPending = lifecycle == .active && file.latest.status == .pending

        return Button {
            if splitMode {
                selectedTopicID = file.id
            } else {
                model.topicToOpen = file.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    statusIndicator(lifecycle: lifecycle, latestStatus: file.latest.status)
                    Text(file.title)
                        .font(.system(size: 14.5, weight: isSelected ? .bold : .semibold))
                        .foregroundStyle(RecallPalette.text)
                        .lineLimit(1)
                    if isBlocked {
                        Text(t("卡住了", "Blocked"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .foregroundStyle(RecallPalette.warning)
                            .background(RecallPalette.warning.opacity(0.12), in: Capsule())
                    } else if isPending {
                        Text(t("还没做", "To do"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .foregroundStyle(RecallPalette.accent)
                            .background(RecallPalette.accent.opacity(0.11), in: Capsule())
                    }
                    Spacer(minLength: 6)
                    if model.completingMatterIDs.contains(file.id) {
                        Text(t("保存中…", "Saving…"))
                            .font(.caption2)
                            .foregroundStyle(RecallPalette.secondary)
                    } else if reading.timelineEntries.count > 1 {
                        Text("\(reading.timelineEntries.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(RecallPalette.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RecallPalette.border.opacity(0.45), in: Capsule())
                    }
                    Text(TopicListPresentation.relativeTime(file.latest.date))
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                }
                Text(reading.headline)
                    .font(.system(size: 13))
                    .foregroundStyle(RecallPalette.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 18)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? RecallPalette.selected : RecallPalette.surface.opacity(splitMode ? 0.65 : 1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? RecallPalette.accent.opacity(0.65) : RecallPalette.border.opacity(0.65), lineWidth: 1)
        )
        .accessibilityIdentifier("open-topic-" + file.id)
        .contextMenu {
            topicContextMenu(file, lifecycle: lifecycle)
        }
    }

    @ViewBuilder
    private func statusIndicator(lifecycle: Topic.Lifecycle, latestStatus: WorkEpisodeStatus) -> some View {
        switch lifecycle {
        case .done, .archived:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(RecallPalette.accent.opacity(0.75))
                .frame(width: 10)
        case .dormant:
            Image(systemName: "pause.circle")
                .font(.system(size: 11))
                .foregroundStyle(RecallPalette.secondary)
                .frame(width: 10)
        case .active:
            Circle()
                .fill(latestStatus == .blocked ? RecallPalette.warning : RecallPalette.accent)
                .frame(width: 8, height: 8)
                .frame(width: 10)
        }
    }

    /// Unified right-click menu matching the Topic Detail action vocabulary (`记下进展`、`做完了`、`今天先放下`、`继续问`、`归入项目`).
    @ViewBuilder
    private func topicContextMenu(_ file: MatterFile, lifecycle: Topic.Lifecycle) -> some View {
        Button(t("记下进展", "Log progress")) {
            quickProgressDraft = QuickProgressDraft(topicTitle: file.title, lockedTopic: true)
        }
        if lifecycle == .active {
            Button(t("做完了", "Mark done")) {
                Task { await model.completeMatter(file) }
            }
            .disabled(model.completingMatterIDs.contains(file.id))

            Button(t("今天先放下", "Pause for today")) {
                Task { await model.setTopicLifecycle(id: file.id, fallbackTitle: file.title, lifecycle: .dormant) }
            }
        } else {
            Button(t("恢复跟进", "Resume")) {
                Task { await model.reopenTopic(file) }
            }
            if lifecycle == .dormant {
                Button(t("做完了", "Mark done")) {
                    Task { await model.completeMatter(file) }
                }
            }
        }

        Button(t("继续问", "Continue asking")) {
            model.openTopicConversation(file.id)
        }

        Divider()

        Menu(t("归入项目", "Project")) {
            let currentParentID = model.state.topicRegistry.resolvedTopic(for: file)?.parentID
            ForEach(model.state.topicRegistry.topics.filter(\.isProject)) { project in
                Button {
                    Task { await model.assignProject("topic:" + project.id.uuidString, to: file) }
                } label: {
                    if currentParentID == project.id {
                        Label(project.title, systemImage: "checkmark")
                    } else {
                        Text(project.title)
                    }
                }
            }
            if currentParentID != nil {
                Divider()
                Button(t("移出项目", "Remove from project")) {
                    Task { await model.assignProject(nil, to: file) }
                }
            }
            Divider()
            Button(t("新建项目…", "New project…")) {
                newProjectName = ""
                pendingProjectFor = file
            }
        }
        if file.id.hasPrefix("group:") {
            Button(t("拆分合并主题", "Undo merge")) {
                model.undoTopicMerge(file.id)
            }
        }
        Divider()
        Button(t("删除主题（保留原始记录）…", "Delete topic (keep records)…"), role: .destructive) {
            pendingDelete = file
        }
    }

    private func syncSelectionAndDestination() {
        if let requestedID = model.selectedWorkspaceTopicID {
            tab = .topics
            selectedTopicID = requestedID
            model.selectedWorkspaceTopicID = nil
        } else if selectedTopicID == nil {
            selectedTopicID = lifecycleSections.active.first?.id ?? model.matterFiles.first?.id
        }
        if case .knowledge = model.destination { tab = .knowledge; model.destination = nil }
        if case .record = model.destination { tab = .timeline }
    }
}

// MARK: - Modal Sheet Entry Point (from Today / Global Search / Narrow Mode)

struct TopicDetailView: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let topicID: String
    let continueChat: (String) -> Void
    @State private var pendingProjectFor: MatterFile?
    @State private var newProjectName = ""
    @State private var pendingDelete: MatterFile?

    private var preferredHeight: CGFloat {
        let count = model.matterFiles.first(where: { $0.id == topicID })?.events.count ?? 2
        return min(720, max(440, 340 + CGFloat(min(count, 4)) * 80))
    }

    var body: some View {
        TopicDetailContentView(
            topicID: topicID,
            embedded: false,
            onDismiss: { dismiss() },
            requestNewProject: { file in
                newProjectName = ""
                pendingProjectFor = file
            },
            requestDeleteTopic: { file in
                pendingDelete = file
            },
            onAsk: { id, question in
                dismiss()
                if let question {
                    model.openTopicConversation(id, question: question)
                } else {
                    model.openTopicConversation(id)
                }
            }
        )
        .frame(minWidth: 620, idealWidth: 780, minHeight: 400, idealHeight: preferredHeight)
        .background(RecallPalette.background)
        .alert(t("新建项目分组", "New project"),
               isPresented: Binding(get: { pendingProjectFor != nil }, set: { if !$0 { pendingProjectFor = nil } })) {
            TextField(t("项目名称", "Project name"), text: $newProjectName)
            Button(t("取消", "Cancel"), role: .cancel) { pendingProjectFor = nil }
            Button(t("创建", "Create")) {
                let file = pendingProjectFor
                let name = newProjectName
                pendingProjectFor = nil
                Task { await model.createProject(named: name, moving: file) }
            }
        }
        .confirmationDialog(t("删除这个主题？", "Delete this topic?"),
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { file in
            Button(t("删除主题（保留原始记录）", "Delete topic (keep records)"), role: .destructive) {
                pendingDelete = nil
                Task {
                    await model.deleteTopic(file)
                    dismiss()
                }
            }
        } message: { _ in
            Text(t("只移除主题、小结与完成标记，原始记录和截图不会删除。", "Only the topic, its summary and completion mark are removed. Records and screenshots are kept."))
        }
    }
}

// MARK: - Three-Layer Topic Detail: 「现在 → 经过 → 动作」

private struct TopicDetailContentView: View {
    @EnvironmentObject private var model: RecallAppModel
    let topicID: String
    let embedded: Bool
    var onDismiss: (() -> Void)? = nil
    let requestNewProject: (MatterFile) -> Void
    let requestDeleteTopic: (MatterFile) -> Void
    let onAsk: (String, String?) -> Void

    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var showsInlineComposer = false
    @State private var progressText = ""
    @State private var progressStatus: WorkEpisodeStatus = .progressed
    @State private var composerMarksNextStep = false
    @State private var isSavingProgress = false
    @State private var showsOlderEntries = false
    @State private var agreement = false
    @State private var aliases = false
    @State private var showsAllSources = false
    @State private var source: CaptureRecord?
    @State private var correcting: MatterEvent?
    @State private var quickQuestion = ""

    private var file: MatterFile? {
        let canonical = model.state.canonicalTopicID(topicID)
        return model.matterFiles.first { $0.id == topicID || model.state.canonicalTopicID($0.id) == canonical }
    }

    private func topicAgreements(for file: MatterFile) -> [MemoryClaim] {
        let canonical = model.state.canonicalTopicID(file.id)
        return model.state.memoryKnowledge.claims.filter { claim in
            claim.usable() && claim.kind.isPersonal && claim.scope == .project
                && (claim.scopeID == file.id || model.state.canonicalTopicID(claim.scopeID ?? "") == canonical)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let file {
                let reading = TopicReading(file: file, review: model.state.topicReviews.first { $0.id == file.id })
                let lifecycle = TopicListPresentation.lifecycle(for: file, registry: model.state.topicRegistry)
                let registered = model.state.topicRegistry.resolvedTopic(for: file)
                let parentProject = registered?.parentID.flatMap { model.state.topicRegistry.topic(id: $0) }

                dossierHeader(file: file, reading: reading, lifecycle: lifecycle, registered: registered, parentProject: parentProject)
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if showsInlineComposer {
                            inlineProgressComposer(for: file)
                        }

                        nowSection(file: file, reading: reading, lifecycle: lifecycle)

                        let agreements = topicAgreements(for: file)
                        if !agreements.isEmpty {
                            agreementsBanner(agreements)
                        }

                        storyTimelineSection(file: file, reading: reading)
                    }
                    .padding(24)
                    .frame(maxWidth: 880, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .clipped()

                Divider()
                actionFooter(file: file, reading: reading, lifecycle: lifecycle)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(t("这个主题已移除或暂无内容", "This topic is no longer available"))
                        .font(.headline)
                    if let onDismiss {
                        Button(t("关闭", "Close"), action: onDismiss)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .sheet(isPresented: $agreement) {
            if let file {
                let topic = MemoryEntity(id: file.id, name: file.title, aliases: [], kind: "topic", sourceIDs: file.evidenceIDs)
                MemoryAgreementEditor(claim: nil, topics: [topic], initialTopic: topic) { content, scope, scopeID, until in
                    await model.saveMemoryAgreement(content: content, scope: scope, scopeID: scopeID, validUntil: until)
                }
            }
        }
        .sheet(isPresented: $aliases) {
            if let file, let entity = model.state.memoryKnowledge.entities.first(where: { $0.id == file.id }) {
                MemoryAliasEditor(entity: entity) { await model.saveMemoryAliases(entity: entity, text: $0) }
            }
        }
        .sheet(isPresented: $showsAllSources) {
            if let file {
                RecallSourcesView(title: file.title, ids: file.evidenceIDs).environmentObject(model)
            }
        }
        .sheet(item: $source) { CaptureDetailSheet(capture: $0).environmentObject(model) }
        .sheet(item: $correcting) { event in
            MatterCorrectionSheet(event: event) { model.correctMatter($0); correcting = nil }
        }
    }

    // MARK: - Header

    private func dossierHeader(
        file: MatterFile,
        reading: TopicReading,
        lifecycle: Topic.Lifecycle,
        registered: Topic?,
        parentProject: Topic?
    ) -> some View {
        let allAliases = Array(Set((registered?.aliases ?? []) + (model.state.memoryKnowledge.entities.first { $0.id == file.id }?.aliases ?? []))).sorted()

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if isRenaming {
                    HStack(spacing: 8) {
                        TextField(t("输入新的主题名称", "New topic name"), text: $renameDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.headline)
                            .onSubmit { commitRename(file) }
                        Button(t("保存", "Save")) { commitRename(file) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                        Button(t("取消", "Cancel")) { isRenaming = false }
                            .controlSize(.small)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(file.title)
                            .font(.title2.bold())
                            .textSelection(.enabled)
                        Button {
                            renameDraft = file.title
                            isRenaming = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(RecallPalette.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(t("重命名主题（旧名自动存为其他叫法）", "Rename topic (old name kept as alias)"))
                    }
                }

                Spacer(minLength: 8)

                if !embedded {
                    Button {
                        model.openTopicInWorkspace(file.id)
                    } label: {
                        Label(t("在记忆中查看", "Open in Memory"), systemImage: "sidebar.left")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if let onDismiss {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(RecallPalette.secondary)
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(t("关闭", "Close"))
                    }
                }
            }

            HStack(spacing: 8) {
                lifecyclePillMenu(file: file, lifecycle: lifecycle)
                Text("·").foregroundStyle(RecallPalette.secondary)
                projectPillMenu(file: file, parentProject: parentProject)
                Text("·").foregroundStyle(RecallPalette.secondary)
                Text(headerLastConfirmedLabel(reading.lastConfirmedDate))
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
                Spacer(minLength: 0)
            }

            if !allAliases.isEmpty {
                Text(t("其他叫法：", "Also called: ") + allAliases.joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func headerLastConfirmedLabel(_ date: Date) -> String {
        let monthDay = date.formatted(.dateTime.month().day())
        let relative = TopicListPresentation.relativeTime(date)
        if relative == monthDay {
            return t("最后确认于 \(monthDay)", "Last confirmed \(monthDay)")
        }
        return t("最后确认于 \(monthDay)（\(relative)）", "Last confirmed \(monthDay) (\(relative))")
    }

    private func commitRename(_ file: MatterFile) {
        let targetName = renameDraft
        Task {
            if await model.renameTopic(file, to: targetName) {
                isRenaming = false
            }
        }
    }

    private func lifecyclePillMenu(file: MatterFile, lifecycle: Topic.Lifecycle) -> some View {
        let isBlocked = lifecycle == .active && file.latest.status == .blocked
        let labelText: String = switch lifecycle {
        case .done, .archived: t("已做完", "Done")
        case .dormant: t("先放下", "Paused")
        case .active: RecallLocalization.text(file.latest.status.manualMatterLabel)
        }

        return Menu {
            if lifecycle != .active {
                Button(t("恢复跟进", "Resume")) {
                    Task { await model.reopenTopic(file) }
                }
            }
            if lifecycle == .active {
                Button(t("今天先放下", "Pause for today")) {
                    Task { await model.setTopicLifecycle(id: file.id, fallbackTitle: file.title, lifecycle: .dormant) }
                }
            }
            if lifecycle != .done {
                Button(t("做完了", "Mark done")) {
                    Task { await model.completeMatter(file) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(isBlocked ? RecallPalette.warning : (lifecycle == .dormant ? RecallPalette.secondary : RecallPalette.accent))
                    .frame(width: 6, height: 6)
                Text(labelText)
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(isBlocked ? RecallPalette.warning : (lifecycle == .dormant ? RecallPalette.secondary : RecallPalette.accent))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background((isBlocked ? RecallPalette.warning : RecallPalette.accent).opacity(lifecycle == .dormant ? 0.08 : 0.12), in: Capsule())
    }

    private func projectPillMenu(file: MatterFile, parentProject: Topic?) -> some View {
        let projects = model.state.topicRegistry.topics.filter(\.isProject)
        return Menu {
            ForEach(projects) { project in
                Button {
                    Task { await model.assignProject("topic:" + project.id.uuidString, to: file) }
                } label: {
                    if parentProject?.id == project.id {
                        Label(project.title, systemImage: "checkmark")
                    } else {
                        Text(project.title)
                    }
                }
            }
            if parentProject != nil {
                Divider()
                Button(t("移出项目", "Remove from project")) {
                    Task { await model.assignProject(nil, to: file) }
                }
            }
            if !projects.isEmpty { Divider() }
            Button(t("新建项目分组…", "New project…")) {
                requestNewProject(file)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: parentProject == nil ? "folder.badge.plus" : "folder")
                Text(parentProject.map { t("归入项目：\($0.title)", "Project: \($0.title)") } ?? t("归入项目", "Project"))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(RecallPalette.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(RecallPalette.border.opacity(0.38), in: Capsule())
    }

    // MARK: - Layer 1: 「现在」 (Date-Anchored Status & Evidence-Backed Next Step)

    private func nowSection(file: MatterFile, reading: TopicReading, lifecycle: Topic.Lifecycle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Text(t("现在", "Now"))
                        .font(.headline)
                    if reading.hasUpdatedSummary {
                        Text(t("跨日小结", "Synthesized"))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(RecallPalette.accent)
                            .background(RecallPalette.selected, in: Capsule())
                    }
                }
                Spacer()
                Button {
                    showsAllSources = true
                } label: {
                    Text(t("查看来源 (\(file.evidenceIDs.count))", "View sources (\(file.evidenceIDs.count))"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(RecallPalette.accent)
                }
                .buttonStyle(.plain)
            }

            if model.generatingTopicID == file.id {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(t("正在整理跨日小结，下方记录仍可随时阅读…", "Updating cross-day summary; records remain readable…"))
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                    Spacer()
                    Button(RecallLocalization.text("停止生成")) { model.cancelTopicReview() }
                        .controlSize(.mini)
                }
            }

            Text(
                AttributedString(reading.lastConfirmedAnchor())
                + ReviewTextHighlight.attributed(reading.currentStatusSummary)
            )
            .font(.system(size: 15))
            .lineSpacing(4.5)
            .foregroundStyle(RecallPalette.text)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)

            if lifecycle == .active, let next = reading.openNextAction {
                let provenance = reading.nextActionOrigin == .userNote
                    ? t("来自你的留话", "from your note")
                    : t("来自当日记录", "from saved record")
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(RecallPalette.accent)
                        .padding(.top, 2)
                    Text(t("下一步：\(next)（\(provenance)）", "Next step: \(next) (\(provenance))"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RecallPalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button(t("设为提醒", "Remind me")) {
                        model.prepareReminder(
                            title: file.title + "：" + String(next.prefix(40)),
                            detail: reading.currentStatusSummary,
                            sourceIDs: file.latest.evidenceIDs
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(12)
                .background(RecallPalette.accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .recallSurface(padding: 18)
    }

    // MARK: - Layer 2: 「经过」 (De-duplicated Reverse Timeline with Adaptive Folding)

    private func storyTimelineSection(file: MatterFile, reading: TopicReading) -> some View {
        let shouldFoldOlder = reading.collapsesHistoryByDefault && !showsOlderEntries
        let visibleEntries = shouldFoldOlder ? Array(reading.timelineEntries.prefix(1)) : reading.timelineEntries
        let olderEntries = Array(reading.timelineEntries.dropFirst())

        return VStack(alignment: .leading, spacing: 12) {
            Text(t("经过", "Timeline"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                    timelineNodeRow(
                        entry: entry,
                        isLast: index == visibleEntries.count - 1 && (!shouldFoldOlder || olderEntries.isEmpty)
                    )
                }
            }

            if reading.collapsesHistoryByDefault && !olderEntries.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showsOlderEntries.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showsOlderEntries ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                        Text(olderEntriesDisclosureLabel(olderEntries, expanded: showsOlderEntries))
                            .font(.callout.weight(.medium))
                    }
                    .foregroundStyle(RecallPalette.accent)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(RecallPalette.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func olderEntriesDisclosureLabel(_ older: [TopicTimelineEntry], expanded: Bool) -> String {
        if expanded {
            return t("收起之前的记录（\(older.count) 条）", "Hide earlier records (\(older.count))")
        }
        guard let nextOlder = older.first else {
            return t("之前的记录（\(older.count)）", "Earlier records (\(older.count))")
        }
        let dateLabel = nextOlder.date.formatted(.dateTime.month().day())
        let shortHead = String((nextOlder.headline.isEmpty ? nextOlder.body : nextOlder.headline).prefix(20))
        if older.count == 1 {
            return t("之前的记录（1 条：\(dateLabel) \(shortHead)）", "Earlier records (1: \(dateLabel) \(shortHead))")
        }
        return t("之前的记录（\(older.count) 条：\(dateLabel) \(shortHead) 等）", "Earlier records (\(older.count): \(dateLabel) \(shortHead)…)")
    }

    private func timelineNodeRow(entry: TopicTimelineEntry, isLast: Bool) -> some View {
        let isBlocked = entry.status == .blocked
        let dotColor = isBlocked ? RecallPalette.warning : (entry.status == .explored ? RecallPalette.secondary : RecallPalette.accent)
        let sources = entry.evidenceIDs.compactMap { id in
            model.memoryWorkspace?.sources[id] ?? model.state.captures.first { $0.id == id }
        }

        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 9, height: 9)
                    .padding(.top, 6)
                if !isLast {
                    Rectangle()
                        .fill(RecallPalette.border)
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .padding(.top, 4)
                }
            }
            .frame(width: 12)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Text(entry.date.formatted(.dateTime.month().day()))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RecallPalette.secondary)
                    Text(TopicListPresentation.relativeTime(entry.date))
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                    RecallStatusBadge(title: entry.status.manualMatterLabel, warning: isBlocked)

                    Spacer(minLength: 6)

                    Button(t("更正", "Correct")) {
                        correcting = entry.event
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
                }

                if !entry.headline.isEmpty {
                    Text(entry.headline)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RecallPalette.text)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    if !entry.body.isEmpty {
                        Text(ReviewTextHighlight.attributed(entry.body))
                            .font(.system(size: 14))
                            .foregroundStyle(entry.headline.isEmpty ? RecallPalette.text : RecallPalette.text.opacity(0.86))
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }

                if !sources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(sources.prefix(5)) { record in
                                Button {
                                    source = record
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: record.textOrigin == .userInput ? "square.and.pencil" : "doc.text")
                                            .font(.system(size: 10))
                                        Text((record.sourceAppName ?? t("记录", "Record")) + " " + record.createdAt.formatted(date: .omitted, time: .shortened))
                                            .font(.caption2)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .foregroundStyle(RecallPalette.secondary)
                                    .background(RecallPalette.background, in: Capsule())
                                    .overlay(Capsule().stroke(RecallPalette.border, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                            if sources.count > 5 {
                                Button(t("全部 \(sources.count) 条", "All \(sources.count)")) {
                                    showsAllSources = true
                                }
                                .buttonStyle(.plain)
                                .font(.caption2)
                                .foregroundStyle(RecallPalette.accent)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(RecallPalette.border, lineWidth: 1))
            .padding(.bottom, isLast ? 0 : 10)
        }
    }

    // MARK: - Minimal Inline Progress Composer & Topic Instructions

    private func inlineProgressComposer(for file: MatterFile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(composerMarksNextStep ? t("给下次的自己留一句", "Note for next time") : t("记下进展", "Log progress"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                HStack(spacing: 6) {
                    ForEach([WorkEpisodeStatus.progressed, .pending, .blocked, .completed], id: \.self) { item in
                        Button {
                            progressStatus = item
                        } label: {
                            Text(item.progressChoiceLabel)
                                .font(.system(size: 11.5, weight: progressStatus == item ? .semibold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .foregroundStyle(progressStatus == item ? RecallPalette.accent : RecallPalette.secondary)
                                .background(progressStatus == item ? RecallPalette.selected : RecallPalette.border.opacity(0.28), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            TextField(
                composerMarksNextStep
                    ? t("写下下次接手时先从哪一步开始…", "Write what to pick up first next time…")
                    : t("写下这次做了什么、结果怎样，或给下次的自己留一句“下次从哪开始”…", "Write what happened, the outcome, or where to start next…"),
                text: $progressText,
                axis: .vertical
            )
            .lineLimit(2...5)
            .textFieldStyle(.plain)
            .padding(10)
            .background(RecallPalette.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(RecallPalette.border, lineWidth: 1))

            HStack {
                if progressStatus != .completed {
                    Toggle(
                        t("作为下次接手提醒（在「今天 · 接着干」排到首位）", "Pin as my next step on Today"),
                        isOn: $composerMarksNextStep
                    )
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
                } else {
                    Text(t("保存后该主题会归入已做完", "Saving marks this topic as done"))
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                }

                Spacer()

                Button(t("取消", "Cancel")) {
                    showsInlineComposer = false
                    composerMarksNextStep = false
                    progressText = ""
                }
                .controlSize(.small)
                .disabled(isSavingProgress)

                Button(isSavingProgress ? t("保存中…", "Saving…") : t("保存", "Save")) {
                    let trimmed = progressText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let nextStep: String? = (progressStatus != .completed && composerMarksNextStep && !trimmed.isEmpty)
                        ? (ManualMatterNote.extractedNextAction(from: trimmed) ?? LocalBriefing.firstClause(trimmed))
                        : nil
                    let note = ManualMatterNote(
                        title: file.title,
                        detail: progressText,
                        status: progressStatus,
                        eventAt: .now,
                        nextAction: nextStep
                    )
                    guard note.isValid else { return }
                    isSavingProgress = true
                    Task { @MainActor in
                        if await model.saveManualMatter(note) {
                            progressText = ""
                            composerMarksNextStep = false
                            showsInlineComposer = false
                        }
                        isSavingProgress = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isSavingProgress || progressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .recallSurface(padding: 16)
    }

    private func agreementsBanner(_ claims: [MemoryClaim]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(t("已记住的主题要求", "Topic instructions"), systemImage: "pin.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RecallPalette.accent)
                Spacer()
                Button(t("添加", "Add")) { agreement = true }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(RecallPalette.accent)
            }
            ForEach(claims) { claim in
                HStack(alignment: .top, spacing: 8) {
                    Text("· " + claim.content)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(t("移除", "Remove")) {
                        model.retireMemory(claim)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
                }
            }
        }
        .padding(14)
        .background(RecallPalette.selected.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecallPalette.border, lineWidth: 1))
    }

    // MARK: - Layer 3: Fixed High-Frequency Action Bar (`记下进展` · `做完了` · `整理 ▾` · `继续问`)

    private func actionFooter(file: MatterFile, reading: TopicReading, lifecycle: Topic.Lifecycle) -> some View {
        let hasTypedQuestion = !quickQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let prompts = reading.suggestedPrompts(for: file)

        return VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text(t("推荐追问：", "Try asking:"))
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                    ForEach(prompts, id: \.self) { prompt in
                        Button {
                            onAsk(file.id, prompt)
                        } label: {
                            Text(prompt)
                                .font(.caption)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .foregroundStyle(RecallPalette.secondary)
                                .background(RecallPalette.surface, in: Capsule())
                                .overlay(Capsule().stroke(RecallPalette.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        composerMarksNextStep = false
                        showsInlineComposer.toggle()
                    }
                } label: {
                    Label(t("记下进展", "Log progress"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if lifecycle == .active {
                    Button {
                        Task { await model.completeMatter(file) }
                    } label: {
                        Label(t("做完了", "Mark done"), systemImage: "checkmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.completingMatterIDs.contains(file.id))

                    Button(t("今天先放下", "Pause")) {
                        Task { await model.setTopicLifecycle(id: file.id, fallbackTitle: file.title, lifecycle: .dormant) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        Task { await model.reopenTopic(file) }
                    } label: {
                        Label(t("恢复跟进", "Resume"), systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                organizeMenu(file: file, reading: reading, lifecycle: lifecycle)

                Spacer(minLength: 6)

                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.caption)
                        .foregroundStyle(RecallPalette.accent)
                    TextField(t("继续问…", "Ask a follow-up…"), text: $quickQuestion)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .frame(minWidth: 120, maxWidth: 240)
                        .onSubmit {
                            let submitted = quickQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !submitted.isEmpty else { return }
                            quickQuestion = ""
                            onAsk(file.id, submitted)
                        }
                    Button(hasTypedQuestion ? t("提问", "Ask") : t("继续问 →", "Open chat →")) {
                        let submitted = quickQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
                        quickQuestion = ""
                        onAsk(file.id, submitted.isEmpty ? nil : submitted)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .padding(.vertical, 4)
                .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(RecallPalette.border, lineWidth: 1))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(RecallPalette.background)
    }

    private func organizeMenu(file: MatterFile, reading: TopicReading, lifecycle: Topic.Lifecycle) -> some View {
        Menu {
            Button(t("给下次留一句…", "Leave a note for next time…")) {
                withAnimation(.easeInOut(duration: 0.16)) {
                    progressStatus = .pending
                    composerMarksNextStep = true
                    showsInlineComposer = true
                }
            }
            if !file.latest.evidenceIDs.isEmpty {
                Button(t("设为提醒…", "Schedule reminder…")) {
                    let hint = reading.openNextAction ?? reading.headline
                    model.prepareReminder(
                        title: file.title + (hint.isEmpty ? "" : "：" + String(hint.prefix(36))),
                        detail: reading.currentStatusSummary,
                        sourceIDs: file.latest.evidenceIDs
                    )
                }
            }
            if lifecycle == .active {
                Button(t("今天先放下", "Pause for today")) {
                    Task { await model.setTopicLifecycle(id: file.id, fallbackTitle: file.title, lifecycle: .dormant) }
                }
            }
            Divider()
            Button(t("重新整理小结", "Refresh summary")) {
                model.generateTopicReview(file)
            }
            .disabled(model.generatingTopicID != nil)

            Button(t("整理成报告…", "Create report…")) {
                model.reviewTopicToOpen = WeeklyReviewEngine.topicID(for: file)
                model.reviewsRequested = true
                onDismiss?()
            }
            Button(t("记住这个主题的要求…", "Remember topic instruction…")) {
                agreement = true
            }
            Button(t("其他叫法（重命名）…", "Other names (rename)…")) {
                renameDraft = file.title
                isRenaming = true
            }
            if model.state.memoryKnowledge.entities.contains(where: { $0.id == file.id }) {
                Button(t("管理已识别别名…", "Manage entity aliases…")) { aliases = true }
            }
            if file.id.hasPrefix("group:") {
                Button(t("拆分合并主题", "Undo merge")) {
                    model.undoTopicMerge(file.id)
                }
            }
            Divider()
            Button(t("删除主题（保留原始记录）…", "Delete topic (keep records)…"), role: .destructive) {
                requestDeleteTopic(file)
            }
        } label: {
            HStack(spacing: 4) {
                Text(t("整理", "Manage"))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .menuIndicator(.hidden)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
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
    @State private var status: WorkEpisodeStatus = .progressed
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
            Text(t("补记历史时间的记录", "Backdate a record")).font(.title2.bold())
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
                    ForEach([WorkEpisodeStatus.progressed, .pending, .blocked, .completed, .explored], id: \.self) {
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
