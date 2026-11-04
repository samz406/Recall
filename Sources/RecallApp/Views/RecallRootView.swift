import RecallKit
import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RecallRootView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: RecallAppModel
    @AppStorage(RecallLocalization.languageKey) private var interfaceLanguage = "system"
    @State private var section: SidebarSection? = .matters
    @State private var showingRecordSheet = false
    @State private var showingTasks = false
    @State private var returnSection: SidebarSection?
    @State private var noticeDismissal: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            RecallSidebarView(section: $section)
                .navigationSplitViewColumnWidth(min: 180, ideal: 196, max: 220)
                .navigationTitle("")

        } detail: {
            Group {
                switch section ?? .timeline {
                case .matters: MatterWorkspaceView { question in
                    section = .chat
                    model.ask(question)
                }
                case .timeline: TimelineView()
                case .chat: ChatView()
                case .dailySummaries: DailySummariesView()
                case .reminders: RemindersView()
                case .rules: EventRulesView()
                case .privacy: PrivacyAndModelView()
                }
            }
            .background(RecallPalette.background)
            .toolbar {
                activityToolbar
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 12) {
                        if let back = returnSection {
                            Button { section = back; returnSection = nil } label: { Label(RecallLocalization.text("返回"), systemImage: "arrow.left") }
                        }
                        Menu {
                            if let target = model.lastExternalTarget, let rule = model.state.rules.first(where: { $0.template == .manualMoment && $0.isEnabled }) {
                                Button(RecallLocalization.both("记录：", "Record: ") + target.appName) { model.record(rule: rule, targetOverride: target) }.disabled(model.isRecording || model.state.privacy.screenCapturePaused)
                            }
                            Button(RecallLocalization.both("写一条记录", "Write a record")) { model.showsTextEntry = true }
                            Button(RecallLocalization.both("会议记录", "Meeting moments")) { model.showsMeetingPanel = true }
                        } label: { Label(RecallLocalization.text("记录此刻"), systemImage: "plus.square") }
                        Button { model.showsGlobalSearch = true } label: { Label(RecallLocalization.text("搜索记忆"), systemImage: "magnifyingglass") }.keyboardShortcut("f", modifiers: [.command, .shift]).labelStyle(.titleAndIcon)
                        Button { showingTasks.toggle() } label: { Label(RecallLocalization.text("处理任务"), systemImage: model.tasks.contains(where: \.isRunning) ? "clock.badge" : "clock") }
                            .labelStyle(.titleAndIcon).help(RecallLocalization.text("查看处理进度和结果")).popover(isPresented: $showingTasks) { RecallTaskHistory().environmentObject(model) }
                    }
                }
            }
        }
        .environment(\.locale, RecallLocalization.locale)
        .onChange(of: interfaceLanguage) { _, _ in model.noticeMessage = nil }
        .onAppear {
            model.openMainWindow = { openWindow(id: "main"); RecallAppDelegate.activateMainWindow() }
            if model.openAskRequested { section = .chat; model.openAskRequested = false }
        }
        .onChange(of: model.openAskRequested) { _, requested in if requested { section = .chat; model.openAskRequested = false } }
        .onReceive(NotificationCenter.default.publisher(for: .recallOpenAsk)) { _ in section = .chat }
        .onOpenURL { url in
            model.pendingEvidenceURL = url; model.resolveEvidenceURL()
        }
        .onChange(of: model.isLoadingSavedState) { _, loading in
            if !loading && model.state.captures.isEmpty && !model.state.workflow.onboardingCompleted { model.showsOnboarding = true }
        }
        .sheet(isPresented: $model.showsOnboarding) { FirstMomentView().environmentObject(model) }
        .sheet(isPresented: $model.showsMeetingPanel) { MeetingMomentsSheet().environmentObject(model) }
        .sheet(isPresented: $model.showsTextEntry) { TextEvidenceEntrySheet().environmentObject(model) }
        .onChange(of: model.navigationRevision) { _, _ in
            let target = model.destination
            guard let target else { return }
            returnSection = section; showingTasks = false
            switch target {
            case .record: section = .timeline
            case .topic(let id): model.topicToOpen = id; section = .matters
            case .daily(let id): model.dailyToOpen = id; section = .dailySummaries
            case .review(let id): model.weeklyReportToOpen = id; section = .matters
            case .reminder: section = .reminders
            case .knowledge(let id): model.knowledgeToOpen = id; section = .matters
            }
        }
        .sheet(item: $model.summaryFeedbackTarget) { SummaryFeedbackSheet(target: $0).environmentObject(model) }
        .sheet(isPresented: $model.showsSummaryFeedbackHistory) { SummaryFeedbackHistoryView().environmentObject(model) }
        .sheet(isPresented: $model.showsGlobalSearch) { GlobalMemorySearchSheet().environmentObject(model) }
        .onChange(of: model.state.captures.map(\.id)) { _, ids in
            if let source = model.sourceToOpen, !ids.contains(source.id) { model.sourceToOpen = nil }
        }
        .sheet(item: $model.sourceToOpen) { CaptureDetailSheet(capture: $0).environmentObject(model) }
        .sheet(item: $model.reminderDraft) { reminder in
            ReminderScheduleSheet(reminder: reminder, preferredHour: model.state.reminderLearningProfile.preferredHour) { date, recurrence in
                model.approveReminder(reminder, dueAt: date, recurrence: recurrence)
            }
        }
        .sheet(isPresented: $showingRecordSheet) {
            RecordSheet()
                .environmentObject(model)
        }
        .overlay(alignment: .topTrailing) {
            if let notice = model.noticeMessage {
                NoticeBanner(text: notice) {
                    model.noticeMessage = nil
                }
                .frame(width: 380)
                .padding(.top, 54)
                .padding(.trailing, 22)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(100)
            }
        }
        .overlay(alignment: .bottom) {
            if model.addedTodayUndo != nil {
                HStack(spacing: 16) {
                    Label(RecallLocalization.text("已加入今天"), systemImage: "checkmark.circle")
                    Button(RecallLocalization.text("撤销")) { model.undoToday() }
                    Button { model.addedTodayUndo = nil } label: { Image(systemName: "xmark") }
                }.padding(14).background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 10)).padding(.bottom, 22)
            } else if let deletion = model.deletionUndoNotice {
                DeletionUndoBanner(item: deletion, undo: model.undoLastDeletion, dismiss: model.dismissDeletionUndoNotice)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(110)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: model.noticeMessage)
        .task(id: model.deletionUndoNotice?.id) {
            guard let id = model.deletionUndoNotice?.id else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, model.deletionUndoNotice?.id == id else { return }
            model.dismissDeletionUndoNotice()
        }
        .onChange(of: model.noticeMessage) { _, notice in
            noticeDismissal?.cancel()
            guard notice != nil else { return }
            noticeDismissal = Task {
                try? await Task.sleep(nanoseconds: 3_800_000_000)
                guard !Task.isCancelled else { return }
                model.noticeMessage = nil
            }
        }
        .onDisappear {
            noticeDismissal?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recallOpenReminders)) { _ in
            section = .reminders
        }
        .onReceive(NotificationCenter.default.publisher(for: .recallOpenWeeklyReview)) { note in
            if let id = note.userInfo?["weeklyReportID"] as? String { model.weeklyReportToOpen = UUID(uuidString: id) }
            section = .matters
        }
    }

    @ToolbarContentBuilder
    private var activityToolbar: some ToolbarContent {
        if model.isRecording {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                activityToolbarItem.sharedBackgroundVisibility(.hidden)
            } else {
                activityToolbarItem
            }
            #else
            activityToolbarItem
            #endif
        }
    }

    private var activityToolbarItem: some ToolbarContent {
        ToolbarItem(id: "recall-activity", placement: .automatic) {
            // Informational progress, not a button. Keep its host square and opt out
            // of the shared glass above so the toolbar cannot draw a narrow capsule.
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .frame(width: 28, height: 28)
                .help(model.isRecording ? "正在保存记录" : "正在处理内容")
                .accessibilityLabel(model.isRecording ? "正在保存记录" : "正在处理内容")
        }
    }


}

private struct RecallSidebarView: View {
    @EnvironmentObject private var model: RecallAppModel
    @Binding var section: SidebarSection?
    private var proposedReminderCount: Int { model.state.reminders.filter { $0.status == .proposed }.count }
    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    Text("Recall").font(.system(size: 18, weight: .bold)).padding(.horizontal, 12).padding(.top, 14)
                    sidebarGroup("回看", entries: [(.matters, "记忆", "square.stack.3d.up"), (.dailySummaries, "每日回顾", "calendar.badge.clock"), (.timeline, "时间线", "clock.arrow.circlepath")])
                    sidebarGroup("行动", entries: [(.reminders, "提醒", "bell"), (.chat, "问一问", "bubble.left.and.bubble.right")])
                    sidebarGroup("管理", entries: [(.rules, "记录管理", "checklist"), (.privacy, "设置", "gearshape")])
                    Spacer(minLength: 24)
                }.padding(12)
            }.background(RecallPalette.sidebar)
    }
    private func sidebarGroup(_ title: String, entries: [(SidebarSection, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(RecallLocalization.text(title)).font(.caption).foregroundStyle(RecallPalette.secondary).padding(.horizontal, 12).padding(.bottom, 5)
            ForEach(entries, id: \.0) { item in
                Button { section = item.0 } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.2).frame(width: 18)
                        Text(RecallLocalization.text(item.1)).fontWeight(section == item.0 ? .semibold : .regular)
                        Spacer(minLength: 0)
                        if item.0 == .reminders && proposedReminderCount > 0 {
                            Text("\(proposedReminderCount)").font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RecallPalette.surface, in: Capsule())
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                        .foregroundStyle(section == item.0 ? RecallPalette.accent : RecallPalette.text)
                        .background(section == item.0 ? RecallPalette.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityAddTraits(section == item.0 ? .isSelected : [])
            }
        }
    }

}

/// Renders the same sidebar and page without the OS compositor's split-view material layer.
private struct RecallNavigationPreview: View {
    @State private var section: SidebarSection? = .matters
    var body: some View {
        HStack(spacing: 0) {
            RecallSidebarView(section: $section).frame(width: 196)
            MatterWorkspaceView(continueChat: { _ in })
        }
    }
}

private struct DeletionUndoBanner: View {
    let item: RecentlyDeletedMemory
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.circle.fill")
                .font(.title3)
                .foregroundStyle(RecallPalette.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(RecallLocalization.text("已移到最近删除"))
                    .font(.subheadline.weight(.semibold))
                Text(item.label)
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
                    .lineLimit(1)
            }
            Button(RecallLocalization.text("撤销"), action: undo)
                .buttonStyle(.borderedProminent)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(RecallPalette.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(RecallPalette.border, lineWidth: 1))
        .shadow(color: RecallPalette.shadow.opacity(0.16), radius: 14, y: 6)
    }
}

private enum SidebarSection: Hashable {
    case matters, timeline, chat, dailySummaries, reminders, rules, privacy
}

private struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(RecallPalette.accent)
            Text(RecallLocalization.text(text))
                .font(.subheadline)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(RecallPalette.border.opacity(0.6), lineWidth: 1)
        }
        .shadow(color: RecallPalette.shadow.opacity(0.14), radius: 12, y: 5)
    }
}

private struct RecordSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTemplate: CaptureEventTemplate = .manualMoment
    @State private var note = ""

    private var rule: EventRule? {
        model.state.rules.first { $0.template == selectedTemplate }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(RecallLocalization.text("记录一个工作节点"))
                .font(.title2.weight(.semibold))
            Text(RecallLocalization.text("只有在你确认后才会采集。截图、OCR 与索引默认保存在本机。"))
                .foregroundStyle(RecallPalette.secondary)
            Picker(RecallLocalization.text("事件模板"), selection: $selectedTemplate) {
                ForEach(model.state.rules.filter(\.isEnabled)) { rule in
                    Text(rule.template.title).tag(rule.template)
                }
            }
            TextField(RecallLocalization.text("可选备注或待办内容"), text: $note, axis: .vertical)
                .lineLimit(3...6)
            HStack {
                Button(RecallLocalization.text("取消")) { dismiss() }
                Spacer()
                Button(RecallLocalization.text("开始记录")) {
                    guard let rule else { return }
                    model.record(rule: rule, userText: note.isEmpty ? nil : note)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(rule == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct TimelineDeletionRequest: Identifiable {
    let id = UUID()
    let captures: [CaptureRecord]
    let impact: MemoryDeletionImpact
}

private struct TimelineView: View {
    @EnvironmentObject private var model: RecallAppModel
    var body: some View { TimelineContentView(workspace: model.timelineWorkspace) }
}

private struct TimelineContentView: View {
    @ObservedObject var workspace: TimelineWorkspace
    @EnvironmentObject private var model: RecallAppModel
    @State private var visibleDayCount = 14
    @AppStorage("recall.timeline.hideTitles") private var hideTitles = false
    @AppStorage("recall.timeline.detailed") private var detailed = false
    @AppStorage("recall.timeline.collapseDuplicates") private var collapseDuplicates = true
    @State private var showsCalendar = false
    @State private var isManaging = false
    @State private var selectedCaptureIDs: Set<UUID> = []
    @State private var deletionRequest: TimelineDeletionRequest?
    @State private var captureShowingDetail: CaptureRecord?

    private var selectedDay: Date {
        get { workspace.query.day }
        nonmutating set { workspace.query.day = newValue }
    }
    private var searchText: String {
        get { workspace.query.searchText }
        nonmutating set { workspace.query.searchText = newValue }
    }
    private var searchAllDates: Bool {
        get { workspace.query.searchAllDates }
        nonmutating set { workspace.query.searchAllDates = newValue }
    }
    private var sourceFilter: String {
        get { workspace.query.source }
        nonmutating set { workspace.query.source = newValue }
    }
    private var availableDayOptions: [TimelineDayCount] { workspace.days }
    private var captures: [CaptureRecord] { workspace.result.captures }
    private var isSearching: Bool { workspace.query.isSearching }

    var body: some View {
        VStack(spacing: 0) {
            timelineHeader
            toolbar.padding(.horizontal, 24).padding(.bottom, 16)
            if model.isLoadingSavedState {
                ProgressView("正在读取记录…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.state.captures.isEmpty { timelineEmptyState }
            else {
                HStack(alignment: .top, spacing: 18) {
                    dateColumn.frame(width: 158)
                    if workspace.isLoading {
                        ProgressView(isSearching ? "正在搜索记录…" : "正在整理时间线…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if captures.isEmpty { selectedDayEmptyState.frame(maxWidth: .infinity) }
                    else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 20) {
                                    resultsHeading
                                    ForEach(workspace.result.hours) { group in
                                        VStack(alignment: .leading, spacing: 10) {
                                            Text(group.date.formatted(.dateTime.hour().minute())).font(.caption.weight(.semibold)).foregroundStyle(RecallPalette.secondary)
                                            LazyVStack(spacing: 0) {
                                                ForEach(group.clusters) { cluster in
                                                    TimelineClusterRow(cluster: cluster, isManaging: isManaging, selectedIDs: selectedCaptureIDs,
                                                        detailed: detailed, hideTitles: hideTitles, onSelect: toggleSelection, onDelete: requestDeletion, onOpen: { captureShowingDetail = $0 })
                                                }
                                            }.padding(.horizontal, 14).background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecallPalette.border, lineWidth: 1))
                                        }
                                    }
                                }.padding(.bottom, 24)
                            }.clipped().onAppear { locateRequestedRecord(proxy: proxy) }
                                .onChange(of: model.navigationRevision) { _, _ in locateRequestedRecord(proxy: proxy) }
                        }
                    }
                }.padding(.horizontal, 24).padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if case .record(let id) = model.destination, let source = model.state.captures.first(where: { $0.id == id }) {
                selectedDay = Calendar.current.startOfDay(for: source.createdAt)
            }
            updateGrouping()
            visibleDayCount = max(visibleDayCount, (availableDayOptions.firstIndex { $0.day == selectedDay } ?? 0) + 1)
        }
        .onChange(of: model.navigationRevision) { _, _ in
            let target = model.destination
            if case .record(let id) = target, let source = model.state.captures.first(where: { $0.id == id }) { selectedDay = Calendar.current.startOfDay(for: source.createdAt) }
        }
        .onChange(of: collapseDuplicates) { _, _ in updateGrouping() }
        .onChange(of: isManaging) { _, _ in updateGrouping() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)) { _ in
            workspace.update(captures: model.state.captures)
        }
        .safeAreaInset(edge: .bottom) {
            if isManaging { selectionBar }
        }
        .inspector(isPresented: Binding(get: { captureShowingDetail != nil }, set: { if !$0 { captureShowingDetail = nil } })) {
            if let capture = captureShowingDetail {
                CaptureDetailSheet(capture: capture, embedded: true, close: { captureShowingDetail = nil }).environmentObject(model)
                    .inspectorColumnWidth(min: 440, ideal: 500, max: 620)
            }
        }
        .onChange(of: workspace.sourceRevision) { _, _ in
            selectedCaptureIDs.formIntersection(Set(model.state.captures.map(\.id)))
            if let capture = captureShowingDetail {
                captureShowingDetail = model.state.captures.first { $0.id == capture.id }
            }
        }
        .sheet(item: $deletionRequest) { request in
            CaptureDeletionSheet(
                captures: request.captures,
                impact: request.impact
            ) { reason, suppressSimilar in
                model.deleteCaptures(request.captures, reason: reason, suppressSimilar: suppressSimilar)
                selectedCaptureIDs.subtract(request.captures.map(\.id))
                if selectedCaptureIDs.isEmpty { isManaging = false }
            }
        }
    }

    private func locateRequestedRecord(proxy: ScrollViewProxy) {
        guard case .record(let id) = model.destination,
              let capture = model.state.captures.first(where: { $0.id == id }) else { return }
        selectedDay = Calendar.current.startOfDay(for: capture.createdAt); sourceFilter = ""; searchText = ""
        collapseDuplicates = false; updateGrouping(); captureShowingDetail = capture
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
    }
    private var timelineHeader: some View {
        RecallPageHeader(title: "时间线", subtitle: "按日期回看原始记录，随时追溯和管理") { EmptyView() }
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField(RecallLocalization.text(searchAllDates ? "搜索全部日期的记录" : "搜索当天记录"), text: $workspace.query.searchText).textFieldStyle(.roundedBorder).frame(minWidth: 150)
            Menu {
                Toggle(RecallLocalization.text("搜索全部日期"), isOn: $workspace.query.searchAllDates)
                Toggle(RecallLocalization.text("合并相同内容"), isOn: $collapseDuplicates)
                Toggle(RecallLocalization.text("隐藏记录标题"), isOn: $hideTitles)
            } label: { Image(systemName: "line.3.horizontal.decrease") }.fixedSize().help(RecallLocalization.text("搜索范围与显示选项"))
            Picker(RecallLocalization.text("来源"), selection: $workspace.query.source) {
                Text(RecallLocalization.text("全部来源")).tag("")
                ForEach(workspace.sources, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 122)
            Picker(RecallLocalization.text("显示"), selection: $detailed) { Text(RecallLocalization.text("精简")).tag(false); Text(RecallLocalization.text("详细")).tag(true) }.labelsHidden().frame(width: RecallLocalization.isEnglish ? 100 : 76).help(RecallLocalization.text("精简显示标题和应用；详细显示摘要和标签"))
            Button(RecallLocalization.text(isManaging ? "完成" : "选择")) { isManaging.toggle(); if !isManaging { selectedCaptureIDs.removeAll() } }.help(RecallLocalization.text("多选并批量删除记录"))
        }
    }
    private var dateColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 7) {
                Button { showsCalendar = true } label: { Label(RecallLocalization.text("选择日期"), systemImage: "calendar") }.padding(.bottom, 8)
                    .popover(isPresented: $showsCalendar) { TimelineCalendarPopover(selectedDay: selectedDay) { day in selectDay(day); searchAllDates = false; showsCalendar = false } }
                ForEach(Array(availableDayOptions.prefix(visibleDayCount))) { option in
                    let selected = Calendar.current.isDate(option.day, inSameDayAs: selectedDay)
                    Button { selectDay(option.day); searchAllDates = false } label: {
                        VStack(spacing: 7) {
                            HStack {
                                Text(option.day.formatted(.dateTime.month().day())).fontWeight(selected ? .semibold : .regular)
                                Spacer(minLength: 4)
                                Text("\(option.count)").font(.caption).foregroundStyle(RecallPalette.secondary)
                            }
                            GeometryReader { geometry in
                                Capsule().fill(RecallPalette.border).frame(height: 3)
                                Capsule().fill(selected ? RecallPalette.accent : RecallPalette.accent.opacity(0.35))
                                    .frame(width: max(3, geometry.size.width * CGFloat(option.count) / CGFloat(workspace.maximumDayCount)), height: 3)
                            }.frame(height: 3)
                        }.padding(10).background(selected ? RecallPalette.selected : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                    }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(selected ? RecallPalette.accent : RecallPalette.text)
                }
                if availableDayOptions.count > visibleDayCount { Button(RecallLocalization.text("更早")) { visibleDayCount += 30 }.padding(10) }
                Text(RecallLocalization.text("仅显示有记录的日期")).font(.caption2).foregroundStyle(RecallPalette.secondary).padding(.top, 8)
            }
        }.clipped()
    }
    private var resultsHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(searchAllDates && isSearching ? "全部日期" : selectedDay.formatted(.dateTime.month().day().weekday())).font(.system(size: 16, weight: .semibold))
                Text(RecallLocalization.both("\(captures.count) 条记录", "\(captures.count) records") + (captures.count > workspace.result.clusterCount ? RecallLocalization.both(" · 已合并 \(captures.count - workspace.result.clusterCount) 条重复", " · \(captures.count - workspace.result.clusterCount) duplicates grouped") : "")).font(.caption).foregroundStyle(RecallPalette.secondary)
                Spacer()
            }
            Text(workspace.result.sourceSummary).font(.caption).foregroundStyle(RecallPalette.secondary).lineLimit(2)
        }
    }
    private var timelineEmptyState: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(RecallPalette.accent)
                    .frame(width: 58, height: 58)
                    .background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 6) {
                    Text(RecallLocalization.text("从第一条本地记录开始"))
                        .font(.title3.weight(.semibold))
                    Text(RecallLocalization.text("完成屏幕录制授权后，启用的记录管理产生的内容会显示在这里。所有截图、OCR 和索引默认保存在这台 Mac 上。"))
                        .font(.subheadline)
                        .foregroundStyle(RecallPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 22) {
                TimelineEmptyStateStep(
                    number: "1",
                    icon: "checkmark.shield",
                    title: "确认屏幕权限",
                    detail: "只在你主动确认或启用的事件触发时采集。"
                )
                Divider().frame(height: 48)
                TimelineEmptyStateStep(
                    number: "2",
                    icon: "slider.horizontal.3",
                    title: "设置记录管理",
                    detail: "在左侧“记录管理”中选择需要的触发方式。"
                )
                Divider().frame(height: 48)
                TimelineEmptyStateStep(
                    number: "3",
                    icon: "calendar.badge.clock",
                    title: "回看与总结",
                    detail: "记录会按天整理，并可生成每日回顾。"
                )
            }

            HStack(spacing: 12) {
                Button {
                    model.requestScreenRecordingAccess()
                } label: {
                    Label(RecallLocalization.text("检查屏幕权限"), systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                Text(RecallLocalization.text("你随时可以在“设置”中暂停采集或删除本地数据。"))
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
            }
        }
        .padding(28)
        .frame(maxWidth: 820, alignment: .leading)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(RecallPalette.border, lineWidth: 1))
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var selectedDayEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: isSearching ? "magnifyingglass" : "calendar.badge.clock")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(RecallPalette.accent)
            Text(isSearching || !sourceFilter.isEmpty ? "没有符合筛选条件的记录" : "当天没有记录")
                .font(.headline)
            Text(isSearching
                 ? (searchAllDates ? "已搜索全部日期，可以更换关键词或来源。" : "正在搜索所选日期，可更换关键词、日期，或切换为全部日期。")
                 : "\(dayTitle(for: selectedDay)) 暂无匹配记录，可切换左侧日期或清除来源筛选。")
                .font(.subheadline)
                .foregroundStyle(RecallPalette.secondary)
            if isSearching || !sourceFilter.isEmpty { Button(RecallLocalization.text("清除筛选")) { searchText = ""; sourceFilter = "" } }
            if !Calendar.current.isDateInToday(selectedDay) {
                Button(RecallLocalization.text("回到今天")) { selectDay(.now) }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func updateGrouping() {
        let enabled = collapseDuplicates && !isManaging
        if workspace.query.collapseDuplicates != enabled { workspace.query.collapseDuplicates = enabled }
    }

    private func selectDay(_ day: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let normalizedDay = min(calendar.startOfDay(for: day), today)
        selectedDay = normalizedDay
        selectedCaptureIDs.removeAll()
    }

    private func dayTitle(for day: Date) -> String {
        let calendar = Calendar.current
        let date = day.formatted(.dateTime.month().day().weekday(.wide))
        if calendar.isDateInToday(day) { return "今天 · \(date)" }
        if calendar.isDateInYesterday(day) { return "昨天 · \(date)" }
        return date
    }

    private func toggleSelection(_ capture: CaptureRecord) {
        if selectedCaptureIDs.contains(capture.id) {
            selectedCaptureIDs.remove(capture.id)
        } else {
            selectedCaptureIDs.insert(capture.id)
        }
    }

    private func requestDeletion(_ capture: CaptureRecord) {
        requestDeletion([capture])
    }

    private func requestDeletion(_ requestedCaptures: [CaptureRecord]) {
        guard !requestedCaptures.isEmpty else { return }
        deletionRequest = TimelineDeletionRequest(
            captures: requestedCaptures,
            impact: model.deletionImpact(for: requestedCaptures)
        )
    }

    private var selectionBar: some View {
        HStack(spacing: 14) {
            Button(selectedCaptureIDs.count == captures.count ? "取消全选" : "全选当前结果") {
                let visibleIDs = Set(captures.map(\.id))
                if visibleIDs.isSubset(of: selectedCaptureIDs) {
                    selectedCaptureIDs.subtract(visibleIDs)
                } else {
                    selectedCaptureIDs.formUnion(visibleIDs)
                }
            }
            .buttonStyle(.bordered)
            Text("已选择 \(selectedCaptureIDs.count) 条")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button(RecallLocalization.text("移到最近删除"), role: .destructive) {
                requestDeletion(model.state.captures.filter { selectedCaptureIDs.contains($0.id) })
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedCaptureIDs.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct TimelineClusterRow: View {
    let cluster: TimelineRecordCluster
    let isManaging: Bool
    let selectedIDs: Set<UUID>
    let detailed: Bool
    let hideTitles: Bool
    let onSelect: (CaptureRecord) -> Void
    let onDelete: (CaptureRecord) -> Void
    let onOpen: (CaptureRecord) -> Void
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptureRow(capture: cluster.records[0], isManaging: isManaging, isSelected: selectedIDs.contains(cluster.id), onToggleSelection: onSelect, onDelete: onDelete, onOpen: onOpen,
                detailed: detailed, hideTitle: hideTitles, duplicateCount: cluster.records.count).id(cluster.id)
            if cluster.records.count > 1 {
                DisclosureGroup("查看 \(cluster.records.count) 条重复记录", isExpanded: $expanded) {
                    ForEach(Array(cluster.records.dropFirst())) { record in
                        CaptureRow(capture: record, isManaging: isManaging, isSelected: selectedIDs.contains(record.id), onToggleSelection: onSelect, onDelete: onDelete, onOpen: onOpen, detailed: detailed, hideTitle: hideTitles).id(record.id)
                    }
                }.font(.caption).foregroundStyle(RecallPalette.secondary).padding(.bottom, 10)
            }
            Divider()
        }
    }
}

private struct TimelineEmptyStateStep: View {
    let number: String
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(RecallPalette.onAccent)
                .frame(width: 22, height: 22)
                .background(RecallPalette.accent, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TimelineDaySection: View {
    let group: TimelineDayGroup
    let title: String
    let isSearchResult: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    let isManaging: Bool
    let selectedCaptureIDs: Set<UUID>
    let onToggleSelection: (CaptureRecord) -> Void
    let onDelete: (CaptureRecord) -> Void
    let onOpen: (CaptureRecord) -> Void
    var detailed = true
    var collapseDuplicates = false

    var body: some View {
        Section {
            if isExpanded {
                ForEach(TimelineRecordCluster.make(group.captures, enabled: collapseDuplicates)) { cluster in
                    let capture = cluster.records[0]
                    CaptureRow(
                        capture: capture,
                        isManaging: isManaging,
                        isSelected: selectedCaptureIDs.contains(capture.id),
                        onToggleSelection: onToggleSelection,
                        onDelete: onDelete,
                        onOpen: onOpen, detailed: detailed
                    ).id(capture.id)
                        .contextMenu {
                            Button(RecallLocalization.text("查看详情")) { onOpen(capture) }
                            Button(RecallLocalization.text("删除记录"), role: .destructive) { onDelete(capture) }
                        }
                    if cluster.records.count > 1 {
                        DisclosureGroup("另有 \(cluster.records.count - 1) 条相同内容，展开查看") {
                            ForEach(Array(cluster.records.dropFirst())) { duplicate in
                                CaptureRow(capture: duplicate, isManaging: isManaging, isSelected: selectedCaptureIDs.contains(duplicate.id), onToggleSelection: onToggleSelection, onDelete: onDelete, onOpen: onOpen, detailed: detailed).id(duplicate.id)
                            }
                        }.padding(14)
                    }
                    Divider()
                }
            }
        } header: {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RecallLocalization.text(title))
                            .font(.headline)
                        Text(isSearchResult ? "命中 \(group.captures.count) 条" : "\(group.captures.count) 条记录")
                            .font(.caption)
                            .foregroundStyle(RecallPalette.secondary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(RecallPalette.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RecallPalette.background)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding(.bottom, 8)
    }
}

private struct CaptureRow: View {
    let capture: CaptureRecord
    let isManaging: Bool
    let isSelected: Bool
    let onToggleSelection: (CaptureRecord) -> Void
    let onDelete: (CaptureRecord) -> Void
    let onOpen: (CaptureRecord) -> Void
    var detailed = true
    var collapseDuplicates = false
    var hideTitle = false
    var duplicateCount = 1
    @State private var hovered = false

    var body: some View {
        let presentation = CapturePresentation(capture: capture)
        HStack(alignment: .center, spacing: 12) {
            if isManaging {
                Button { onToggleSelection(capture) } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? RecallPalette.accent : RecallPalette.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                if isManaging { onToggleSelection(capture) } else { onOpen(capture) }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    SourceApplicationIcon(capture: capture)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(hideTitle ? (capture.sourceAppName ?? "本地记录") : presentation.title)
                                .font(.headline)
                                .lineLimit(2)
                            if duplicateCount > 1 { Text("×\(duplicateCount)").font(.caption).foregroundStyle(RecallPalette.secondary).padding(.horizontal, 6).padding(.vertical, 2).background(RecallPalette.sidebar, in: Capsule()) }
                            if capture.isRedacted && detailed {
                                Label(RecallLocalization.text("已脱敏"), systemImage: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(RecallPalette.secondary)
                            }
                        }
                        if detailed && !hideTitle && presentation.summary != presentation.title { Text(presentation.summary)
                            .lineLimit(2)
                            .foregroundStyle(RecallPalette.secondary)
                        }
                        HStack(spacing: 8) {
                            Text(capture.createdAt.formatted(date: .omitted, time: .shortened))
                            if let source = capture.sourceAppName { Text(source) }
                            if detailed { Text(capture.eventTemplate.title) }
                        }
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                        if detailed && !presentation.tags.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(presentation.tags.prefix(3), id: \.self) { tag in
                                    Text(tag).lineLimit(1)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(RecallPalette.sidebar, in: Capsule())
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(RecallPalette.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if !isManaging {
                        Text(RecallLocalization.text("详情 ›")).font(.caption).foregroundStyle(RecallPalette.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isManaging ? "选择记录：\(presentation.title)" : "查看详情：\(presentation.title)")
            if !isManaging {
                Button(role: .destructive) { onDelete(capture) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
                .accessibilityLabel("删除记录")
            }
        }
        .padding(.vertical, 12).onHover { hovered = $0 }
        .contextMenu { Button(RecallLocalization.text("查看详情")) { onOpen(capture) }; Button(RecallLocalization.text("删除记录"), role: .destructive) { onDelete(capture) } }
    }
}

private struct SourceApplicationIcon: View {
    let capture: CaptureRecord
    var body: some View {
        Group {
            if let id = capture.sourceBundleIdentifier, let icon = SourceApplicationIcons.image(for: id) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: capture.textOrigin == .userInput ? "square.and.pencil" : "app.fill")
                    .resizable().scaledToFit().foregroundStyle(RecallPalette.accent).padding(5)
            }
        }.frame(width: 30, height: 30).accessibilityLabel(capture.sourceAppName ?? "记录来源")
    }
}

@MainActor
private enum SourceApplicationIcons {
    private static let images = NSCache<NSString, NSImage>()
    private static var unavailable: [String: Date] = [:]
    static func image(for identifier: String) -> NSImage? {
        if let cached = images.object(forKey: identifier as NSString) { return cached }
        if let checked = unavailable[identifier], Date.now.timeIntervalSince(checked) < 300 { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            unavailable[identifier] = .now; return nil
        }
        images.countLimit = 128
        let image = NSWorkspace.shared.icon(forFile: url.path)
        images.setObject(image, forKey: identifier as NSString)
        return image
    }
}

private struct CaptureDeletionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let captures: [CaptureRecord]
    let impact: MemoryDeletionImpact
    let onConfirm: (MemoryDeletionReason, Bool) -> Void
    @State private var reason: MemoryDeletionReason = .noLongerNeeded
    @State private var suppressSimilar = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "trash.slash.fill")
                    .font(.title2)
                    .foregroundStyle(RecallPalette.warning)
                    .frame(width: 48, height: 48)
                    .background(RecallPalette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(captures.count == 1 ? "删除这条记忆？" : "删除 \(captures.count) 条记忆？")
                        .font(.title2.weight(.semibold))
                    Text(RecallLocalization.text("内容会立即退出搜索与问一问，并在最近删除中保留 7 天。"))
                        .foregroundStyle(RecallPalette.secondary)
                }
            }

            impactCard

            Picker(RecallLocalization.text("删除原因"), selection: $reason) {
                ForEach(MemoryDeletionReason.allCases) { Text($0.title).tag($0) }
            }
            Toggle(RecallLocalization.text("以后也忽略相似内容"), isOn: $suppressSimilar)
            Text(RecallLocalization.text("开启后会在本机保存内容特征和来源应用，用于拦截相似采集；可在“设置”中删除规则。"))
                .font(.caption)
                .foregroundStyle(RecallPalette.secondary)

            HStack {
                Button(RecallLocalization.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(RecallLocalization.text("移到最近删除"), role: .destructive) {
                    onConfirm(reason, suppressSimilar)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(captures.isEmpty)
            }
        }
        .padding(26)
        .frame(width: 580)
    }

    private var impactCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(RecallLocalization.text("将同步处理")).font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                impactLine("本地记录", impact.captureCount, "doc.text")
                impactLine("原始截图", impact.screenshotCount, "photo")
                impactLine("受影响总结", impact.summaryCount, "calendar.badge.clock")
                impactLine("总结条目", impact.summaryItemCount, "list.bullet.rectangle")
                impactLine("派生提醒", impact.reminderCount, "bell.slash")
                impactLine("历史回答", impact.conversationCount, "bubble.left.and.bubble.right")
                impactLine("智能状态", impact.intelligenceCount, "brain.head.profile")
            }
        }
        .padding(16)
        .background(RecallPalette.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }

    private func impactLine(_ title: String, _ count: Int, _ icon: String) -> some View {
        Label("\(title) · \(count)", systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(count == 0 ? RecallPalette.secondary : RecallPalette.text)
    }
}

private enum ChatLayout {
    static let readingWidth: CGFloat = 760
    static let edgeInset: CGFloat = 22
    static let avatarSize: CGFloat = 28
    static let avatarGutter: CGFloat = 40
    static let textInset: CGFloat = 20
}

/// Both the scroll document and composer must occupy the viewport before centering
/// their reading column. Reserve the same avatar gutter on each side at narrow widths.
private struct ChatReadingColumn<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .frame(maxWidth: ChatLayout.readingWidth)
            .padding(.horizontal, ChatLayout.edgeInset + ChatLayout.avatarGutter)
            .frame(maxWidth: .infinity)
    }
}

private struct ChatView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var question = ""
    @State private var scrollRequest = 0
    @State private var messageContentFrame: CGRect = .zero
    @State private var messageViewportHeight: CGFloat = 0
    private var scopeTitle: String {
        if let days = model.chatScope.recentDays { return RecallLocalization.both("最近\(days)天", "Last \(days) days") }
        if let id = model.chatScope.topicID { return model.matterFiles.first { $0.id == id }?.title ?? "所选主题" }
        return RecallLocalization.text("全部记忆")
    }

    private var hasChatMessages: Bool {
        model.state.messages.contains { $0.role != .system }
    }

    private var isAtLatestMessage: Bool {
        messageContentFrame.maxY <= messageViewportHeight + 48
    }

    private var showsLatestButton: Bool {
        hasChatMessages && messageViewportHeight > 0
            && messageContentFrame.height > messageViewportHeight + 2
            && !isAtLatestMessage
    }

    private var isCloudModel: Bool {
        model.state.llmConfiguration.provider != .localOnly && model.state.privacy.cloudUseEnabled
    }

    var body: some View {
        ZStack {
            RecallPalette.background
                .ignoresSafeArea()
            VStack(spacing: 0) {
                chatHeader
                Divider().opacity(0.55)
                if !hasChatMessages && !model.isThinking {
                    ChatReadingColumn {
                        ChatWelcomeView(receipt: model.state.messages.last.flatMap { $0.role == .system ? $0.content : nil })
                    }
                } else {
                    messageTimeline
                }
                if !model.isThinking && model.typingMessageID == nil {
                    ChatReadingColumn {
                        HStack(spacing: 8) {
                            ForEach(["总结本周进展", "我答应了谁什么事？", "上次讨论的结论是什么？"], id: \.self) { prompt in
                                Button(prompt) { question = prompt }.buttonStyle(.plain).font(.caption).padding(.horizontal, 8).padding(.vertical, 5).background(RecallPalette.border.opacity(0.3), in: Capsule())
                            }
                            Spacer(minLength: 0)
                        }
                    }.padding(.top, 8)
                }
                ChatComposer(
                    question: $question,
                    isSending: model.isThinking || model.typingMessageID != nil,
                    onSend: send
                )
                .zIndex(1)
            }
        }
        .onExitCommand {
            if model.isThinking || model.typingMessageID != nil { model.stopChat() }
        }
    }

    private var chatHeader: some View {
        RecallPageHeader(title: "问一问", subtitle: "基于你的本地记忆，回答带来源") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { scopeControl; modelStatus; newConversation }
                VStack(alignment: .trailing, spacing: 8) { HStack { scopeControl; newConversation }; modelStatus }
            }
        }
    }
    private var scopeControl: some View {
        Menu {
            Button(RecallLocalization.text("全部记忆")) { model.chatScope = .all }
            Button(RecallLocalization.text("最近七天")) { setRange(days: 7) }
            Button(RecallLocalization.text("最近三十天")) { setRange(days: 30) }
            if !model.matterFiles.isEmpty {
                Menu(RecallLocalization.text("指定主题")) {
                    ForEach(model.matterFiles) { file in
                        Button(file.title) { model.chatScope = MemoryQueryScope(topicID: file.id) }
                    }
                }
            }
        } label: { Label(RecallLocalization.text("范围：") + scopeTitle, systemImage: "line.3.horizontal.decrease") }
            .disabled(model.isThinking || model.typingMessageID != nil).help(RecallLocalization.text("限制本次提问检索的记忆范围"))
    }
    private func setRange(days: Int) {
        model.chatScope = MemoryQueryScope(recentDays: days)
    }
    private var modelStatus: some View {
        Label(isCloudModel ? model.state.llmConfiguration.model + RecallLocalization.both(" · 仅发脱敏文本", " · Redacted text only") : RecallLocalization.both("本地模式 · 数据不外发", "Local mode · Stays on this Mac"), systemImage: isCloudModel ? "cloud" : "lock")
            .font(.caption).foregroundStyle(RecallPalette.secondary).lineLimit(1).help(isCloudModel ? model.state.llmConfiguration.provider.title : "未启用云端模型")
    }
    private var newConversation: some View {
        Button { question = ""; model.ask("/clear") } label: { Label(RecallLocalization.text("新对话"), systemImage: "plus") }
    }

    private var messageTimeline: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    ChatReadingColumn {
                        VStack(spacing: 16) {
                            ForEach(model.state.messages.filter { $0.role != .system || $0.id == model.state.messages.last?.id }) { message in
                                RecallMessageCard(
                                    message: message,
                                    displayedContent: message.id == model.typingMessageID ? model.typingMessageContent : message.content,
                                    isTyping: message.id == model.typingMessageID,
                                    userMaxWidth: min(ChatLayout.readingWidth, max(100, viewport.size.width - 2 * (ChatLayout.edgeInset + ChatLayout.avatarGutter))) * 0.7
                                )
                                .id(message.id)
                            }
                            if model.isThinking && model.typingMessageID == nil {
                                ThinkingCard()
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(ChatScrollAnchor.bottom)
                        }
                    }
                    .padding(.vertical, 30)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(
                                key: ChatContentFrameKey.self,
                                value: content.frame(in: .named(ChatScrollAnchor.viewport))
                            )
                        }
                    }
                }
                .coordinateSpace(name: ChatScrollAnchor.viewport)
                .onPreferenceChange(ChatContentFrameKey.self) { frame in
                    // Older SwiftUI SDKs expose this callback as Sendable, not MainActor.
                    Task { @MainActor in messageContentFrame = frame }
                }
                .overlay(alignment: .bottom) {
                    if showsLatestButton {
                        ChatReadingColumn {
                            HStack {
                                Spacer(minLength: 0)
                                Button {
                                    scrollToLatest(using: proxy)
                                } label: {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(RecallPalette.accent)
                                        .frame(width: 36, height: 36)
                                        .background(RecallPalette.surface, in: Circle())
                                        .overlay(Circle().stroke(RecallPalette.border.opacity(0.65), lineWidth: 1))
                                        .shadow(color: RecallPalette.shadow.opacity(0.12), radius: 4, y: 2)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help(RecallLocalization.text("跳到最新消息"))
                                .accessibilityLabel("跳到最新消息")
                            }
                        }
                        .padding(.bottom, 18)
                    }
                }
                .onAppear {
                    messageViewportHeight = viewport.size.height
                    scrollToLatest(using: proxy, animated: false)
                }
                .onChange(of: viewport.size.height) { _, height in
                    messageViewportHeight = height
                }
                .onChange(of: model.state.messages.last?.id) { _, _ in
                    if isAtLatestMessage || model.state.messages.last?.role == .user || !hasChatMessages {
                        scrollToLatest(using: proxy)
                    }
                }
                .onChange(of: model.isThinking) { _, _ in
                    if isAtLatestMessage { scrollToLatest(using: proxy) }
                }
                .onChange(of: model.typingMessageContent) { _, _ in
                    if isAtLatestMessage { scrollToLatest(using: proxy, animated: false) }
                }
                .onChange(of: scrollRequest) { _, _ in
                    scrollToLatest(using: proxy, animated: false)
                }
            }
        }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
            }
        }
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        scrollRequest += 1
        model.ask(text)
    }
}

private enum ChatScrollAnchor {
    static let bottom = "chat-scroll-bottom"
    static let viewport = "chat-scroll-viewport"
}

private struct ChatContentFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct ChatWelcomeView: View {
    let receipt: String?
    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 32)
            Image(systemName: "brain.head.profile").font(.system(size: 36, weight: .light)).foregroundStyle(RecallPalette.accent)
            Text(RecallLocalization.text("今天想回忆什么？")).font(.system(size: 24, weight: .semibold))
            Text(RecallLocalization.text("从过去的记录里，找回进展、约定和当时的结论。"))
                .font(.callout).foregroundStyle(RecallPalette.secondary).multilineTextAlignment(.center)
            if let receipt { Text(receipt).font(.caption).foregroundStyle(RecallPalette.accent).multilineTextAlignment(.center) }
            Spacer(minLength: 32)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecallMessageCard: View {
    @EnvironmentObject private var model: RecallAppModel
    let message: ConversationMessage
    let displayedContent: String
    let isTyping: Bool
    var userMaxWidth: CGFloat = ChatLayout.readingWidth * 0.7
    var body: some View {
        Group {
            if message.role == .system {
                Text(displayedContent).font(.caption).foregroundStyle(RecallPalette.secondary).frame(maxWidth: .infinity).padding(.vertical, 8)
            } else if message.role == .user {
                HStack {
                    Spacer(minLength: 30)
                    Text(displayedContent).font(RecallTypography.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 14))
                        .frame(maxWidth: userMaxWidth, alignment: .trailing)
                }.frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    MarkdownParagraphText(markdown: isTyping ? displayedContent : ChatResponseFormatter().format(displayedContent))
                    if isTyping {
                        ChatThinkingWave()
                    } else {
                        ChatAnswerSources(workspace: model.chatSources, citations: message.citations)
                        HStack(spacing: 14) {
                            Button(RecallLocalization.text("复制")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.content, forType: .string) }
                            Menu {
                                Button(RecallLocalization.text("复制并附来源")) { model.exportAnswer(message, toFile: false) }
                                Button(RecallLocalization.text("导出 Markdown")) { model.exportAnswer(message, toFile: true) }
                            } label: { Image(systemName: "square.and.arrow.up") }.disabled(message.citations.isEmpty)
                            Button(RecallLocalization.text("重新回答")) { if let index = model.state.messages.firstIndex(where: { $0.id == message.id }), let question = model.state.messages[..<index].last(where: { $0.role == .user })?.content { model.ask(question) } }.disabled(model.isThinking || model.typingMessageID != nil)
                            Button { model.rateChatMessage(message, helpful: true) } label: { Image(systemName: message.helpful == true ? "hand.thumbsup.fill" : "hand.thumbsup") }.help(RecallLocalization.text("回答有帮助"))
                            Button { model.rateChatMessage(message, helpful: false) } label: { Image(systemName: message.helpful == false ? "hand.thumbsdown.fill" : "hand.thumbsdown") }.help(RecallLocalization.text("回答不准确"))
                        }.buttonStyle(.plain).font(.caption).foregroundStyle(RecallPalette.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .topLeading) {
                        Image(systemName: "sparkle").font(.caption.weight(.semibold)).foregroundStyle(RecallPalette.onAccent)
                            .frame(width: ChatLayout.avatarSize, height: ChatLayout.avatarSize)
                            .background(RecallPalette.accent, in: RoundedRectangle(cornerRadius: 8)).offset(x: -ChatLayout.avatarGutter)
                    }
            }
        }
    }
}

private struct MarkdownParagraphText: View {
    let markdown: String

    private var paragraphs: [String] {
        markdown
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { item in
                Text(markdownAttributedString(from: item.element))
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func markdownAttributedString(from source: String) -> AttributedString {
        guard !source.isEmpty else { return AttributedString() }
        if let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)) {
            return parsed
        }
        return AttributedString(source)
    }
}

private struct ThinkingCard: View {
    @EnvironmentObject private var model: RecallAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: model.chatEvidenceCount == nil ? "magnifyingglass" : "checkmark.circle").foregroundStyle(RecallPalette.accent)
                Text(model.chatEvidenceCount.map { RecallLocalization.both("已检索记忆（\($0) 条）· 正在整理回答", "Found \($0) sources · Writing an answer") } ?? RecallLocalization.both("正在检索记忆", "Searching your memory"))
                    .font(.callout).foregroundStyle(RecallPalette.secondary)
                ChatThinkingWave()
                Spacer(minLength: 0)
            }
            if !model.typingMessageContent.isEmpty {
                MarkdownParagraphText(markdown: model.typingMessageContent)
            }
        }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatComposer: View {
    @EnvironmentObject private var model: RecallAppModel
    @Binding var question: String
    let isSending: Bool
    let onSend: () -> Void
    @State private var isFocused = false
    @State private var editorHeight: CGFloat = 44
    @State private var dismissedCommandQuery: String?

    private var commandSuggestions: [ChatCommand] {
        guard isFocused, dismissedCommandQuery != question else { return [] }
        return ChatCommand.suggestions(for: question)
    }

    var body: some View {
        ChatReadingColumn { editor }
            .padding(.vertical, 16)
            .onChange(of: question) { _, value in
                if value != dismissedCommandQuery { dismissedCommandQuery = nil }
            }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RecallChatInput(text: $question, height: $editorHeight, onFocus: { isFocused = $0 }, onSubmit: {
                    if let command = commandSuggestions.first { insertCommand(command) } else { submit() }
                }, onTab: {
                    guard let command = commandSuggestions.first else { return false }
                    insertCommand(command); return true
                }, onEscape: {
                    if !commandSuggestions.isEmpty { dismissedCommandQuery = question }
                    else if isSending { model.stopChat() }
                })
                    .frame(height: editorHeight)
                if question.isEmpty {
                    Text(RecallLocalization.text("向 Recall 提问…")).font(.system(size: 16)).foregroundStyle(RecallPalette.secondary).allowsHitTesting(false)
                }

            }
            .frame(minHeight: 42, alignment: .topLeading)
            HStack {
                Text(RecallLocalization.text("↵ 发送    ⇧↵ 换行")).font(.caption).foregroundStyle(RecallPalette.secondary)
                Spacer()
                sendControl
            }
        }
        .padding(.top, 12)
        .padding(.leading, ChatLayout.textInset)
        .padding(.trailing, 10)
        .padding(.bottom, 10)
        .frame(minHeight: 92, alignment: .top)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isFocused ? RecallPalette.accent.opacity(0.65) : RecallPalette.border.opacity(0.55), lineWidth: isFocused ? 1.5 : 1)
        }
        .shadow(color: RecallPalette.shadow.opacity(isFocused ? 0.09 : 0.055), radius: isFocused ? 20 : 14, y: 6)
        .animation(.easeOut(duration: 0.16), value: isFocused)
        .overlay(alignment: .top) {
            if !commandSuggestions.isEmpty {
                commandMenu
                    .alignmentGuide(.top) { $0[.bottom] + 10 }
            }
        }
    }

    private var canSend: Bool {
        (!isSending || ChatCommand.parse(question) == .clear)
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder private var sendControl: some View {
        if isSending && ChatCommand.parse(question) != .clear {
            ProgressView().controlSize(.small)
                .frame(width: 32, height: 32)
                .background(RecallPalette.selected, in: Circle())
                .accessibilityLabel(RecallLocalization.both("正在回答，按 Esc 停止", "Answering. Press Escape to stop."))
                .help(RecallLocalization.both("正在回答；按 Esc 停止", "Answering · Press Esc to stop"))
        } else {
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(RecallPalette.onAccent)
                    .frame(width: 32, height: 32)
                    .background(sendButtonColor, in: Circle())
                    .contentShape(Circle())
            }.buttonStyle(.plain).disabled(!canSend)
                .accessibilityLabel(ChatCommand.parse(question) == .clear ? "清空当前会话" : "发送消息")
        }
    }

    private var commandMenu: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(commandSuggestions) { command in
                Button { insertCommand(command) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: command.symbol)
                            .font(.system(size: 19))
                            .frame(width: 28)
                        Text(command.rawValue)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        Text(command.detail)
                            .font(.system(size: 14))
                            .foregroundStyle(RecallPalette.secondary)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.turn.down.left")
                            .foregroundStyle(RecallPalette.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(command.rawValue + "，" + command.title)
                .focusable(false)
                .help(RecallLocalization.text("填入命令后，发送才会执行"))
            }
            Text(RecallLocalization.text("点击或按 Tab / 回车填入，发送后执行"))
                .font(.caption)
                .foregroundStyle(RecallPalette.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
        }
        .padding(8)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RecallPalette.border.opacity(0.5), lineWidth: 1))
        .shadow(color: RecallPalette.shadow.opacity(0.12), radius: 18, y: 6)
    }

    private func insertCommand(_ command: ChatCommand) {
        dismissedCommandQuery = command.rawValue
        question = command.rawValue
        isFocused = true
    }

    private var sendButtonColor: Color {
        canSend ? RecallPalette.accent : RecallPalette.secondary.opacity(0.45)
    }

    private func submit() {
        guard canSend else { return }
        onSend()
    }
}

extension RecallRootView {
    @MainActor static func previewPage(_ name: String) -> AnyView {
        switch name {
        case "preferences": AnyView(PrivacyAndModelView(initialCategory: "使用偏好"))
        case "first-moment": AnyView(FirstMomentView())
        case "sample": AnyView(FirstMomentView(sampleMode: true))
        case "navigation": AnyView(RecallNavigationPreview())
        case "daily", "daily-long": AnyView(DailySummariesView())
        case "topics", "period", "period-stale", "knowledge", "knowledge-empty": AnyView(MatterWorkspaceView(continueChat: { _ in }))
        case "rules": AnyView(EventRulesView())
        case "reminders": AnyView(RemindersView())
        case "reminder-new": AnyView(NewReminderSheet(preferredHour: 9, onCreate: { _, _, _, _ in }))
        case "reminder-calendar": AnyView(ReminderCalendarPreview())
        case "reminder-history", "reminder-history-empty": AnyView(RemindersView(initialTab: 2))
        case "reminder-history-hover": AnyView(RemindersView(initialTab: 2, previewHistoryHover: true))
        case "timeline": AnyView(TimelineView())
        case "settings": AnyView(PrivacyAndModelView())
        case "appearance": AnyView(PrivacyAndModelView(initialCategory: "外观"))
        case "appearance-compact": AnyView(RecallSettingsPreview())
        case "model-editor": AnyView(ModelConnectionEditorSheet(configuration: LLMConfiguration(provider: .anthropicCompatible, baseURLString: "https://model.example.invalid/anthropic", model: "Example-Flash", apiKey: "synthetic-layout-credential"), savedKeyExists: true, onSave: { _, _ in }))
        case "model-editor-new": AnyView(ModelConnectionEditorSheet(configuration: LLMConfiguration(), savedKeyExists: false, onSave: { _, _ in }))
        case "model-editor-success", "model-editor-failure": AnyView(ModelConnectionStatusPreview(fails: name.hasSuffix("failure")))
        case "chat-sources": AnyView(ChatSourcesPreview())
        default: AnyView(ChatView())
        }
    }
}

private struct RecallSettingsPreview: View {
    var body: some View { PrivacyAndModelView(initialCategory: "外观").padding() }
}

private struct ModelConnectionStatusPreview: View {
    let fails: Bool
    @StateObject private var draft = ModelConnectionDraft(configuration: LLMConfiguration(baseURLString: "https://model.example.invalid/v1", model: "Example-Flash", apiKey: "synthetic-layout-credential"), savedKeyExists: true)
    var body: some View {
        ModelConnectionEditorSheet(draft: draft).task {
            let fails = fails
            draft.test { _ in if fails { throw URLError(.cannotConnectToHost) } }
        }
    }
}
