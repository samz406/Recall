import RecallKit
import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RecallRootView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var section: SidebarSection? = .matters
    @State private var showingRecordSheet = false
    @State private var showingTasks = false
    @State private var returnSection: SidebarSection?
    @State private var noticeDismissal: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    Text("Recall").font(.system(size: 18, weight: .bold)).padding(.horizontal, 12).padding(.top, 14)
                    sidebarGroup("回看", entries: [(.matters, "记忆", "square.stack.3d.up"), (.dailySummaries, "每日回顾", "calendar.badge.clock"), (.timeline, "时间线", "clock.arrow.circlepath")])
                    sidebarGroup("行动", entries: [(.reminders, "提醒", "bell"), (.chat, "问一问", "bubble.left.and.bubble.right")])
                    sidebarGroup("管理", entries: [(.rules, "记录管理", "checklist"), (.privacy, "设置", "gearshape")])
                    Spacer(minLength: 24)
                }.padding(12)
            }.background(RecallPalette.sidebar)
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
                            Button { section = back; returnSection = nil } label: { Label("返回", systemImage: "arrow.left") }
                        }
                        Button { model.showsGlobalSearch = true } label: { Label("搜索记忆", systemImage: "magnifyingglass") }.keyboardShortcut("f", modifiers: [.command, .shift]).labelStyle(.titleAndIcon)
                        Button { showingTasks.toggle() } label: { Label("处理任务", systemImage: model.tasks.contains(where: \.isRunning) ? "clock.badge" : "clock") }
                            .labelStyle(.titleAndIcon).help("查看处理进度和结果").popover(isPresented: $showingTasks) { RecallTaskHistory().environmentObject(model) }
                    }
                }
            }
        }
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
            if let deletion = model.deletionUndoNotice {
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

    private func sidebarGroup(_ title: String, entries: [(SidebarSection, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(RecallPalette.secondary).padding(.horizontal, 12).padding(.bottom, 5)
            ForEach(entries, id: \.0) { item in
                Button { section = item.0 } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.2).frame(width: 18)
                        Text(item.1).fontWeight(section == item.0 ? .semibold : .regular)
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

    private var highPrioritySummaryTodoCount: Int {
        model.state.dailySummaries.first?.todos.filter {
            $0.priority == .high && ($0.status == .pending || $0.status == .inProgress)
        }.count ?? 0
    }

    private var proposedReminderCount: Int {
        model.state.reminders.filter { $0.status == .proposed }.count
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
                Text("已移到最近删除")
                    .font(.subheadline.weight(.semibold))
                Text(item.label)
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
                    .lineLimit(1)
            }
            Button("撤销", action: undo)
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
            Text(text)
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
            Text("记录一个工作节点")
                .font(.title2.weight(.semibold))
            Text("只有在你确认后才会采集。截图、OCR 与索引默认保存在本机。")
                .foregroundStyle(RecallPalette.secondary)
            Picker("事件模板", selection: $selectedTemplate) {
                ForEach(model.state.rules.filter(\.isEnabled)) { rule in
                    Text(rule.template.title).tag(rule.template)
                }
            }
            TextField("可选备注或待办内容", text: $note, axis: .vertical)
                .lineLimit(3...6)
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("开始记录") {
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

private struct TimelineDayOption: Identifiable {
    let day: Date
    let count: Int
    var id: Date { day }
}

private struct TimelineDeletionRequest: Identifiable {
    let id = UUID()
    let captures: [CaptureRecord]
    let impact: MemoryDeletionImpact
}

private struct TimelineView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var searchText = ""
    @State private var searchAllDates = false
    @State private var visibleDayCount = 14
    @AppStorage("recall.timeline.hideTitles") private var hideTitles = false
    @State private var expandedDayIDs: Set<Date> = []
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @AppStorage("recall.timeline.detailed") private var detailed = false
    @AppStorage("recall.timeline.collapseDuplicates") private var collapseDuplicates = true
    @State private var sourceFilter = ""
    @State private var showsCalendar = false
    @State private var isManaging = false
    @State private var selectedCaptureIDs: Set<UUID> = []
    @State private var deletionRequest: TimelineDeletionRequest?
    @State private var captureShowingDetail: CaptureRecord?

    private var availableDayOptions: [TimelineDayOption] {
        let calendar = Calendar.current
        let counts = model.state.captures.reduce(into: [Date: Int]()) { result, capture in
            result[calendar.startOfDay(for: capture.createdAt), default: 0] += 1
        }
        return counts.keys
            .sorted(by: >)
            .map { TimelineDayOption(day: $0, count: counts[$0] ?? 0) }
    }

    private var selectedDayCaptures: [CaptureRecord] {
        TimelineGrouping.captures(on: selectedDay, from: model.state.captures).filter { sourceFilter.isEmpty || $0.sourceAppName == sourceFilter }
    }

    private var captures: [CaptureRecord] {
        let pool = (searchAllDates && isSearching ? model.state.captures : selectedDayCaptures)
            .filter { sourceFilter.isEmpty || $0.sourceAppName == sourceFilter }
        guard isSearching else { return pool }
        return MemorySearchEngine().search(MemorySearchQuery(text: searchText), in: pool, limit: Int.max).map(\.capture)
    }

    private var dayGroups: [TimelineDayGroup] {
        TimelineGrouping.dayGroups(for: captures)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            timelineHeader
            toolbar.padding(.horizontal, 24).padding(.bottom, 16)
            if model.state.captures.isEmpty { timelineEmptyState }
            else {
                HStack(alignment: .top, spacing: 18) {
                    dateColumn.frame(width: 158)
                    if captures.isEmpty { selectedDayEmptyState.frame(maxWidth: .infinity) }
                    else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 20) {
                                    resultsHeading
                                    ForEach(hourGroups, id: \.date) { group in
                                        VStack(alignment: .leading, spacing: 10) {
                                            Text(group.date.formatted(.dateTime.hour().minute())).font(.caption.weight(.semibold)).foregroundStyle(RecallPalette.secondary)
                                            VStack(spacing: 0) {
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
            initializeExpandedDays()
        }
        .onChange(of: model.navigationRevision) { _, _ in
            let target = model.destination
            if case .record(let id) = target, let source = model.state.captures.first(where: { $0.id == id }) { selectedDay = Calendar.current.startOfDay(for: source.createdAt) }
        }
        .onChange(of: searchText) { _, _ in initializeExpandedDays() }
        .onChange(of: selectedDay) { _, _ in initializeExpandedDays() }
        .onChange(of: dayGroups.map(\.id)) { _, _ in initializeExpandedDays() }
        .safeAreaInset(edge: .bottom) {
            if isManaging { selectionBar }
        }
        .inspector(isPresented: Binding(get: { captureShowingDetail != nil }, set: { if !$0 { captureShowingDetail = nil } })) {
            if let capture = captureShowingDetail {
                CaptureDetailSheet(capture: capture, embedded: true, close: { captureShowingDetail = nil }).environmentObject(model)
                    .inspectorColumnWidth(min: 440, ideal: 500, max: 620)
            }
        }
        .onChange(of: model.state.captures.map(\.id)) { _, ids in
            selectedCaptureIDs.formIntersection(ids)
            if let capture = captureShowingDetail, !ids.contains(capture.id) {
                captureShowingDetail = nil
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
        collapseDuplicates = false; initializeExpandedDays(); captureShowingDetail = capture
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
    }
    private var timelineHeader: some View {
        RecallPageHeader(title: "时间线", subtitle: "按日期回看原始记录，随时追溯和管理") { EmptyView() }
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField(searchAllDates ? "搜索全部日期的记录" : "搜索当天记录", text: $searchText).textFieldStyle(.roundedBorder).frame(minWidth: 150)
            Menu {
                Toggle("搜索全部日期", isOn: $searchAllDates)
                Toggle("合并相同内容", isOn: $collapseDuplicates)
                Toggle("隐藏记录标题", isOn: $hideTitles)
            } label: { Image(systemName: "line.3.horizontal.decrease") }.fixedSize().help("搜索范围与显示选项")
            Picker("来源", selection: $sourceFilter) {
                Text("全部来源").tag("")
                ForEach(Array(Set(model.state.captures.compactMap(\.sourceAppName))).sorted(), id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 122)
            Picker("显示", selection: $detailed) { Text("精简").tag(false); Text("详细").tag(true) }.labelsHidden().frame(width: 76).help("精简显示标题和应用；详细显示摘要和标签")
            Button(isManaging ? "完成" : "选择") { isManaging.toggle(); if !isManaging { selectedCaptureIDs.removeAll() } }.help("多选并批量删除记录")
        }
    }
    private var dateColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 7) {
                Button { showsCalendar = true } label: { Label("选择日期", systemImage: "calendar") }.padding(.bottom, 8)
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
                                    .frame(width: max(3, geometry.size.width * CGFloat(option.count) / CGFloat(availableDayOptions.map(\.count).max() ?? 1)), height: 3)
                            }.frame(height: 3)
                        }.padding(10).background(selected ? RecallPalette.selected : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                    }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(selected ? RecallPalette.accent : RecallPalette.text)
                }
                if availableDayOptions.count > visibleDayCount { Button("更早") { visibleDayCount += 30 }.padding(10) }
                Text("仅显示有记录的日期").font(.caption2).foregroundStyle(RecallPalette.secondary).padding(.top, 8)
            }
        }.clipped()
    }
    private var resultClusters: [TimelineRecordCluster] {
        TimelineRecordCluster.make(captures.sorted { $0.createdAt > $1.createdAt }, enabled: collapseDuplicates && !isManaging)
    }
    private var hourGroups: [TimelineHourGroup] {
        Dictionary(grouping: resultClusters) { Calendar.current.dateInterval(of: .hour, for: $0.records[0].createdAt)?.start ?? $0.records[0].createdAt }
            .map { TimelineHourGroup(date: $0.key, clusters: $0.value) }.sorted { $0.date > $1.date }
    }
    private var resultsHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(searchAllDates && isSearching ? "全部日期" : selectedDay.formatted(.dateTime.month().day().weekday())).font(.system(size: 16, weight: .semibold))
                Text("\(captures.count) 条记录" + (captures.count > resultClusters.count ? " · 已合并 \(captures.count - resultClusters.count) 条重复" : "")).font(.caption).foregroundStyle(RecallPalette.secondary)
                Spacer()
            }
            Text(sourceSummary).font(.caption).foregroundStyle(RecallPalette.secondary).lineLimit(2)
        }
    }
    private var sourceSummary: String {
        Dictionary(grouping: captures, by: { $0.sourceAppName ?? "其他" }).map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }.prefix(4).map { "\($0.0) \($0.1)" }.joined(separator: " · ")
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
                    Text("从第一条本地记录开始")
                        .font(.title3.weight(.semibold))
                    Text("完成屏幕录制授权后，启用的记录管理产生的内容会显示在这里。所有截图、OCR 和索引默认保存在这台 Mac 上。")
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
                    Label("检查屏幕权限", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                Text("你随时可以在“设置”中暂停采集或删除本地数据。")
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
            Text(isSearching ? "当天没有匹配的记录" : "当天没有记录")
                .font(.headline)
            Text(isSearching
                 ? "搜索只作用于当前选择的日期，可更换关键词或切换日期。"
                 : "\(dayTitle(for: selectedDay)) 暂无本地记录，可通过上方日期栏查看其他日期。")
                .font(.subheadline)
                .foregroundStyle(RecallPalette.secondary)
            if !Calendar.current.isDateInToday(selectedDay) {
                Button("回到今天") { selectDay(.now) }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var dayNavigator: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { moveSelectedDay(by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .help("前一天")

                Button {
                    showsCalendar.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text(selectedDay.formatted(.dateTime.year().month().day()))
                            .fontWeight(.medium)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RecallPalette.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .help("选择日期")
                .accessibilityLabel("选择日期")
                .accessibilityValue(selectedDay.formatted(date: .complete, time: .omitted))
                .popover(isPresented: $showsCalendar, arrowEdge: .top) {
                    TimelineCalendarPopover(selectedDay: selectedDay) { day in
                        selectDay(day)
                        showsCalendar = false
                    }
                }

                Button { moveSelectedDay(by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .disabled(Calendar.current.isDateInToday(selectedDay))
                .help("后一天")

                if !Calendar.current.isDateInToday(selectedDay) {
                    Button("今天") { selectDay(.now) }
                        .buttonStyle(.borderedProminent)
                }

                Spacer()

                Label("\(selectedDayCaptures.count) 条记录", systemImage: "doc.text")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(RecallPalette.secondary)
            }

            if !availableDayOptions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(availableDayOptions) { option in
                            dayButton(for: option)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 14)
    }

    private func dayButton(for option: TimelineDayOption) -> some View {
        let isSelected = Calendar.current.isDate(option.day, inSameDayAs: selectedDay)
        return Button {
            selectDay(option.day)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(navigationTitle(for: option.day))
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 4) {
                    Text(option.day.formatted(.dateTime.weekday(.abbreviated)))
                    Text("·")
                    Text("\(option.count) 条")
                }
                .font(.caption)
                .foregroundStyle(isSelected ? RecallPalette.onAccent.opacity(0.82) : RecallPalette.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? RecallPalette.onAccent : RecallPalette.text)
            .background(
                isSelected ? RecallPalette.accent : RecallPalette.surface,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.clear : RecallPalette.border.opacity(0.6), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func initializeExpandedDays() {
        expandedDayIDs = Set(dayGroups.map(\.id))
    }

    private func toggle(_ day: Date) {
        if expandedDayIDs.contains(day) {
            expandedDayIDs.remove(day)
        } else {
            expandedDayIDs.insert(day)
        }
    }

    private func selectDay(_ day: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let normalizedDay = min(calendar.startOfDay(for: day), today)
        selectedDay = normalizedDay
        selectedCaptureIDs.removeAll()
        expandedDayIDs = [normalizedDay]
    }

    private func moveSelectedDay(by dayOffset: Int) {
        guard let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: selectedDay) else { return }
        selectDay(day)
    }

    private func navigationTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        return day.formatted(.dateTime.month().day())
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
            Button("移到最近删除", role: .destructive) {
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

private struct TimelineHourGroup {
    let date: Date
    let clusters: [TimelineRecordCluster]
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
                            Button("查看详情") { onOpen(capture) }
                            Button("删除记录", role: .destructive) { onDelete(capture) }
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
                        Text(title)
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
                                Label("已脱敏", systemImage: "lock.fill")
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
                        Text("详情 ›").font(.caption).foregroundStyle(RecallPalette.secondary)
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
        .contextMenu { Button("查看详情") { onOpen(capture) }; Button("删除记录", role: .destructive) { onDelete(capture) } }
    }
}

private struct SourceApplicationIcon: View {
    let capture: CaptureRecord
    var body: some View {
        Group {
            if let id = capture.sourceBundleIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
            } else {
                Image(systemName: capture.textOrigin == .userInput ? "square.and.pencil" : "app.fill")
                    .resizable().scaledToFit().foregroundStyle(RecallPalette.accent).padding(5)
            }
        }.frame(width: 30, height: 30).accessibilityLabel(capture.sourceAppName ?? "记录来源")
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
                    Text("内容会立即退出搜索与问一问，并在最近删除中保留 7 天。")
                        .foregroundStyle(RecallPalette.secondary)
                }
            }

            impactCard

            Picker("删除原因", selection: $reason) {
                ForEach(MemoryDeletionReason.allCases) { Text($0.title).tag($0) }
            }
            Toggle("以后也忽略相似内容", isOn: $suppressSimilar)
            Text("开启后会在本机保存内容特征和来源应用，用于拦截相似采集；可在“设置”中删除规则。")
                .font(.caption)
                .foregroundStyle(RecallPalette.secondary)

            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("移到最近删除", role: .destructive) {
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
            Text("将同步处理").font(.headline)
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
        if let days = model.chatScope.recentDays { return "最近\(days)天" }
        if let id = model.chatScope.topicID { return model.matterFiles.first { $0.id == id }?.title ?? "所选主题" }
        return "全部记忆"
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
                        ChatWelcomeView(onSelect: { question = $0 })
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
            Button("全部记忆") { model.chatScope = .all }
            Button("最近七天") { setRange(days: 7) }
            Button("最近三十天") { setRange(days: 30) }
            if !model.matterFiles.isEmpty {
                Menu("指定主题") {
                    ForEach(model.matterFiles) { file in
                        Button(file.title) { model.chatScope = MemoryQueryScope(topicID: file.id) }
                    }
                }
            }
        } label: { Label("范围：" + scopeTitle, systemImage: "line.3.horizontal.decrease") }
            .disabled(model.isThinking || model.typingMessageID != nil).help("限制本次提问检索的记忆范围")
    }
    private func setRange(days: Int) {
        model.chatScope = MemoryQueryScope(recentDays: days)
    }
    private var modelStatus: some View {
        Label(isCloudModel ? model.state.llmConfiguration.model + " · 仅发脱敏文本" : "本地模式 · 数据不外发", systemImage: isCloudModel ? "cloud" : "lock")
            .font(.caption).foregroundStyle(RecallPalette.secondary).lineLimit(1).help(isCloudModel ? model.state.llmConfiguration.provider.title : "未启用云端模型")
    }
    private var newConversation: some View {
        Button { question = ""; model.ask("/clear") } label: { Label("新对话", systemImage: "plus") }
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
                            if model.isThinking {
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
                .onPreferenceChange(ChatContentFrameKey.self) { messageContentFrame = $0 }
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
                                .help("跳到最新消息")
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
    let onSelect: (String) -> Void

    private let suggestions = [
        ("今天做了什么？", "clock.arrow.circlepath", "汇总今天记录到的工作节点"),
        ("我答应谁做什么？", "checklist", "查找待办、承诺与截止事项"),
        ("上周讨论过什么？", "person.2", "从会议、文档与网页记忆中检索"),
        ("帮我整理研究线索", "wand.and.stars", "把已保存的材料组织成摘要")
    ]

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(RecallPalette.accent)
                .frame(width: 76, height: 76)
                .background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 24))
            VStack(spacing: 8) {
                Text("今天想回忆什么？")
                    .font(.system(size: 28, weight: .semibold))
                Text("Recall 会先检索相关记忆，再给出带来源的回答。")
                    .foregroundStyle(RecallPalette.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(suggestions, id: \.0) { suggestion in
                    Button {
                        onSelect(suggestion.0)
                    } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            Image(systemName: suggestion.1)
                                .foregroundStyle(RecallPalette.accent)
                            Text(suggestion.0)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(RecallPalette.text)
                            Text(suggestion.2)
                                .font(.caption)
                                .foregroundStyle(RecallPalette.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                        .padding(16)
                        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(RecallPalette.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 720)
            Spacer()
        }
    }
}

private struct RecallMessageCard: View {
    @EnvironmentObject private var model: RecallAppModel
    let message: ConversationMessage
    let displayedContent: String
    let isTyping: Bool
    var userMaxWidth: CGFloat = ChatLayout.readingWidth * 0.7
    private var sources: [CaptureRecord] { model.state.captures.filter { message.citations.contains($0.id) } }
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
                        RoundedRectangle(cornerRadius: 1).fill(RecallPalette.accent).frame(width: 2, height: 16)
                        Button("停止") { model.stopChat() }.font(.caption)
                    } else {
                        if !sources.isEmpty {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) { sourceLabels }
                                VStack(alignment: .leading, spacing: 8) { sourceLabels }
                            }
                        }
                        HStack(spacing: 14) {
                            Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.content, forType: .string) }
                            Button("重新回答") { if let index = model.state.messages.firstIndex(where: { $0.id == message.id }), let question = model.state.messages[..<index].last(where: { $0.role == .user })?.content { model.ask(question) } }.disabled(model.isThinking || model.typingMessageID != nil)
                            Button { model.rateChatMessage(message, helpful: true) } label: { Image(systemName: message.helpful == true ? "hand.thumbsup.fill" : "hand.thumbsup") }.help("回答有帮助")
                            Button { model.rateChatMessage(message, helpful: false) } label: { Image(systemName: message.helpful == false ? "hand.thumbsdown.fill" : "hand.thumbsdown") }.help("回答不准确")
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
    @ViewBuilder private var sourceLabels: some View {
        ForEach(Array(sources.prefix(2))) { source in
            Button { model.sourceToOpen = source } label: {
                Label((source.sourceAppName ?? "时间线") + " · " + source.createdAt.formatted(.dateTime.month().day().hour().minute()), systemImage: "paperclip")
                    .font(.caption).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 4).background(RecallPalette.border.opacity(0.25), in: Capsule())
            }.buttonStyle(.plain).foregroundStyle(RecallPalette.secondary)
        }
        if sources.count > 2 {
            Menu("另有 \(sources.count - 2) 条来源") { ForEach(Array(sources.dropFirst(2))) { source in Button(CapturePresentation(capture: source).title) { model.sourceToOpen = source } } }.font(.caption)
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
        HStack(spacing: 10) {
            Image(systemName: model.chatEvidenceCount == nil ? "magnifyingglass" : "checkmark.circle").foregroundStyle(RecallPalette.accent)
            Text(model.chatEvidenceCount.map { "已检索记忆（\($0) 条） → 整理回答中…" } ?? "正在检索记忆…").font(.callout).foregroundStyle(RecallPalette.secondary)
            Button("停止") { model.stopChat() }
            Spacer(minLength: 0)
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
                }, onEscape: { dismissedCommandQuery = question })
                    .frame(height: editorHeight)
                if question.isEmpty {
                    Text("向 Recall 提问…").font(.system(size: 16)).foregroundStyle(RecallPalette.secondary).allowsHitTesting(false)
                }

            }
            .frame(minHeight: 42, alignment: .topLeading)
            HStack {
                Text("↵ 发送    ⇧↵ 换行").font(.caption).foregroundStyle(RecallPalette.secondary)
                Spacer()
                if isSending { Button("停止") { model.stopChat() }.font(.caption) }
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(RecallPalette.onAccent)
                        .frame(width: 32, height: 32)
                        .background(sendButtonColor, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
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
                .help("填入命令后，发送才会执行")
            }
            Text("点击或按 Tab / 回车填入，发送后执行")
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

private struct DailySummariesView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var selectedID: UUID?
    @State private var selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
    @State private var showsCalendar = false
    @State private var managing: DailySummary?
    @State private var visibleCount = 30
    private var summaries: [DailySummary] { model.state.dailySummaries.sorted { $0.day > $1.day } }
    private var selected: DailySummary? { summaries.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            RecallPageHeader(title: "每日回顾", subtitle: "回看一天里值得记住的事") {
                HStack(spacing: 10) {
                    Button { showsCalendar = true } label: {
                        Label(selectedDate.formatted(.dateTime.month().day()), systemImage: "calendar")
                    }.popover(isPresented: $showsCalendar) {
                        TimelineCalendarPopover(selectedDay: selectedDate) { day in
                            selectedDate = day
                            selectedID = summaries.first { Calendar.current.isDate($0.day, inSameDayAs: day) }?.id
                            showsCalendar = false
                        }
                    }
                    Button("生成回顾") { model.generateDailyReview(on: selectedDate) }
                        .buttonStyle(.borderedProminent).disabled(model.isLoadingSavedState || model.isGeneratingDailySummary)
                }
            }
            if model.isLoadingSavedState {
                ProgressView("正在读取已保存的回顾…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    dateList.frame(width: 214)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let task = model.tasks.first(where: { $0.kind == "每日回顾" }), task.isRunning || task.state == .failed || task.state == .partial {
                                RecallTaskStatusView(task: task, cancel: model.cancelDailyReview)
                            }
                            if let selected {
                                DailySummaryCard(summary: selected, isExpanded: true, onToggle: {}, onManage: { managing = selected }, onReviewInsight: { model.reviewInsight($0, rating: $1) }, onUpdateRoutine: { model.updateLearnedRoutine($0, status: $1) })
                            } else {
                                VStack(spacing: 14) {
                                    Image(systemName: "calendar").font(.system(size: 34, weight: .light)).foregroundStyle(RecallPalette.accent)
                                    Text(summaries.isEmpty ? "还没有每日回顾" : "这一天还没有回顾").font(.headline)
                                    Text("选择日期，生成这一天值得记住的事。").foregroundStyle(RecallPalette.secondary)
                                    Button("生成回顾") { model.generateDailyReview(on: selectedDate) }.buttonStyle(.borderedProminent).disabled(model.isGeneratingDailySummary)
                                }.frame(maxWidth: .infinity, minHeight: 360).recallSurface()
                            }
                        }.padding(.bottom, 24)
                    }.clipped().id(selectedID)
                }.padding(.horizontal, 24).padding(.bottom, 16)
            }
        }.onAppear { openSelection() }
            .onChange(of: model.dailyToOpen) { _, id in if let id { select(id) } }
            .onChange(of: model.state.dailySummaries.map(\.id)) { _, ids in
                if selectedID == nil || !ids.contains(selectedID!) { openSelection() }
            }
            .onChange(of: model.navigationRevision) { _, _ in if case .daily(let id) = model.destination { select(id) } }
            .sheet(item: $managing) { DailySummaryManagementSheet(summary: $0).environmentObject(model) }
    }
    private var dateList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text("已保存 \(summaries.count) 天").font(.caption).foregroundStyle(RecallPalette.secondary).padding(.bottom, 4)
                ForEach(Array(summaries.prefix(visibleCount))) { summary in
                    RecallListChoice(title: summary.day.formatted(.dateTime.month().day().weekday()), detail: keywords(summary), selected: selectedID == summary.id) { select(summary.id) }
                }
                if summaries.count > visibleCount { Button("更早的回顾") { visibleCount += 30 }.padding(.vertical, 8) }
            }
        }.clipped()
    }
    private func keywords(_ summary: DailySummary) -> String {
        let topics = summary.items.filter { $0.section.canonical == .progress }.map { $0.knowledge?.topic ?? $0.title }
        var seen = Set<String>()
        let words = topics.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(2)
        return words.isEmpty ? "查看当天回顾" : words.joined(separator: " · ")
    }
    private func select(_ id: UUID) {
        guard let item = summaries.first(where: { $0.id == id }) else { return }
        selectedID = id; selectedDate = item.day; model.dailyToOpen = id
        visibleCount = max(visibleCount, (summaries.firstIndex { $0.id == id } ?? 0) + 1)
    }
    private func openSelection() {
        if let id = model.dailyToOpen, summaries.contains(where: { $0.id == id }) { select(id) }
        else if let id = summaries.first?.id { select(id) }
        else { selectedID = nil }
    }
}

private struct DailySummaryCard: View {
    let summary: DailySummary
    let isExpanded: Bool
    let onToggle: () -> Void
    let onManage: () -> Void
    let onReviewInsight: (PersonalInsight, InsightFeedbackRating) -> Void
    let onUpdateRoutine: (LearnedRoutine, LearnedRoutineStatus) -> Void

    private var displayContent: String {
        if !summary.items.isEmpty {
            return DailySummaryItemParser.markdown(from: summary.items)
        }
        guard summary.generationKind == .cloud else {
            return DailySummaryContentFormatter.removingCitationMarkers(from: summary.content)
        }
        let todoActions = summary.todos.map(\.title)
        let briefingActions = summary.briefing?.nextActions.map { "\($0.title)：\($0.detail)" } ?? []
        return DailySummaryContentFormatter.normalizingNextActionSection(
            in: summary.content,
            fallbackActions: todoActions + briefingActions
        )
    }

    private var preview: String {
        if summary.generationKind == .localFallback, let briefing = summary.briefing {
            return DailySummaryContentFormatter.removingCitationMarkers(from: briefing.headline)
        }
        if let overview = summary.modelOverview, !overview.isEmpty { return overview }
        let text = displayContent
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .prefix(3)
            .joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        return text.isEmpty ? "这条总结暂无可预览内容。" : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 15 : 9) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(summary.day.formatted(.dateTime.month().day().weekday())).font(.system(size: 20, weight: .semibold))
                    Text("更新于 " + summary.createdAt.formatted(date: .omitted, time: .shortened) + " · 已保存")
                        .font(.caption).foregroundStyle(RecallPalette.secondary)
                }
                Spacer(minLength: 8)
                Button("重新生成") { model.generateDailyReview(on: summary.day) }.disabled(model.isGeneratingDailySummary)
                Menu {
                    Button("管理这份回顾", action: onManage)
                    Button("反馈整份回顾") { model.summaryFeedbackTarget = .daily(summary) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多回顾操作")
            }
            if isExpanded {
                Divider()
                if let overview = summary.modelOverview, !overview.isEmpty {
                    Text(DailySummaryContentFormatter.removingCitationMarkers(from: overview)).font(.system(size: 15, weight: .medium)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 10))
                }
                if !summary.items.isEmpty {
                    DailyReviewContentView(summary: summary)
                        .textSelection(.enabled)
                } else if summary.generationKind == .cloud {
                    MarkdownDocumentView(markdown: displayContent)
                        .textSelection(.enabled)
                } else if let briefing = summary.briefing {
                    DailyBriefingView(
                        briefing: briefing,
                        feedback: summaryFeedback,
                        routineStates: routineStates,
                        onReviewInsight: onReviewInsight,
                        onUpdateRoutine: onUpdateRoutine
                    )
                } else {
                    MarkdownDocumentView(markdown: displayContent)
                        .textSelection(.enabled)
                }
            } else {
                Text(preview)
                    .font(.system(size: 15))
                    .foregroundStyle(RecallPalette.secondary)
                    .lineLimit(2)
                    .padding(.leading, 34)
            }
        }
        .padding(isExpanded ? 19 : 15)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(isExpanded ? RecallPalette.accent.opacity(0.28) : RecallPalette.border, lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @EnvironmentObject private var model: RecallAppModel

    private var summaryFeedback: [UUID: InsightFeedbackRating] {
        Dictionary(uniqueKeysWithValues: model.state.insightFeedback.map { ($0.insightID, $0.rating) })
    }

    private var routineStates: [UUID: LearnedRoutineStatus] {
        Dictionary(uniqueKeysWithValues: model.state.learnedRoutines.map { ($0.id, $0.status) })
    }

    private var activeActionCount: Int {
        summary.todos.filter { $0.status == .pending || $0.status == .inProgress }.count
    }
}

private struct DailySummaryItemsView: View {
    let items: [DailySummaryItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(DailySummarySection.displaySections) { section in
                let sectionItems = items.filter { $0.section == section }
                if !sectionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Label(section.title, systemImage: section.systemImage)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(color(for: section))
                        ForEach(sectionItems) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                if !item.detail.isEmpty, item.detail != item.title {
                                    Text(item.detail)
                                        .font(.system(size: 15))
                                        .foregroundStyle(RecallPalette.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.leading, 2)
                        }
                    }
                }
            }
        }
    }

    private func color(for section: DailySummarySection) -> Color {
        switch section {
        case .headline, .nextActions: RecallPalette.accent
        case .progress: RecallPalette.accent
        case .openLoops, .todos, .actions: RecallPalette.warning
        case .insights: RecallPalette.accent
        case .recent: RecallPalette.accent
        }
    }
}

private struct DailySummaryManagementSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let summary: DailySummary
    @State private var pendingForgetItem: DailySummaryItem?
    @State private var isConfirmingSummaryDeletion = false
    @State private var sourceItem: DailySummaryItem?

    private var currentSummary: DailySummary {
        model.state.dailySummaries.first(where: { $0.id == summary.id }) ?? summary
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2)
                    .foregroundStyle(RecallPalette.onAccent)
                    .frame(width: 46, height: 46)
                    .background(RecallPalette.accent, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("管理每日回顾")
                        .font(.title2.weight(.semibold))
                    Text(summary.day.formatted(.dateTime.year().month().day().weekday()))
                        .foregroundStyle(RecallPalette.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(DailySummarySection.displaySections) { section in
                        let sectionItems = currentSummary.items.filter { $0.section == section }
                        if !sectionItems.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(section.title, systemImage: section.systemImage)
                                    .font(.headline)
                                ForEach(sectionItems) { item in
                                    HStack(alignment: .top, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.title).font(.system(size: 15, weight: .semibold))
                                            if !item.detail.isEmpty, item.detail != item.title {
                                                Text(item.detail).font(.system(size: 14)).foregroundStyle(RecallPalette.secondary).lineLimit(3)
                                            }
                                            Label("关联 \(item.evidenceIDs.count) 条原始记忆", systemImage: "link")
                                                .font(.caption)
                                                .foregroundStyle(RecallPalette.secondary)
                                        }
                                        Spacer()
                                        Button {
                                            sourceItem = item
                                        } label: {
                                            Label("来源", systemImage: "link")
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(item.evidenceIDs.isEmpty)
                                        Menu {
                                            Button("只删除这条总结内容") {
                                                model.removeSummaryItem(item, from: currentSummary, reason: .noLongerNeeded)
                                            }
                                            Button("连同原始记录一起删除…", role: .destructive) {
                                                pendingForgetItem = item
                                            }
                                        } label: {
                                            Label("处理", systemImage: "ellipsis.circle")
                                        }
                                        .menuStyle(.borderlessButton)
                                        .fixedSize()
                                    }
                                    .padding(14)
                                    .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecallPalette.border, lineWidth: 1))
                                }
                            }
                        }
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("只删除这份总结").font(.headline)
                            Text("原始记录会保留，之后仍可重新生成。")
                                .font(.caption).foregroundStyle(RecallPalette.secondary)
                        }
                        Spacer()
                        Button("删除总结", role: .destructive) { isConfirmingSummaryDeletion = true }
                            .buttonStyle(.bordered)
                    }
                    .padding(16)
                    .background(RecallPalette.danger.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(RecallPalette.danger.opacity(0.18), lineWidth: 1))
                }
                .padding(24)
            }
        }
        .frame(width: 760, height: 720)
        .sheet(item: $sourceItem) { item in
            SummaryItemSourceSheet(
                item: item,
                captures: model.state.captures.filter { item.evidenceIDs.contains($0.id) }
            )
        }
        .sheet(item: $pendingForgetItem) { item in
            SummarySourceDeletionSheet(
                item: item,
                sourceCount: item.evidenceIDs.isEmpty ? currentSummary.sourceCaptureIDs.count : item.evidenceIDs.count
            ) { reason, suppressSimilar in
                model.forgetSources(
                    for: item,
                    in: currentSummary,
                    reason: reason,
                    suppressSimilar: suppressSimilar
                )
            }
        }
        .confirmationDialog("只删除这份总结？", isPresented: $isConfirmingSummaryDeletion) {
            Button("删除总结", role: .destructive) {
                model.deleteDailySummary(currentSummary)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("原始记录不会被删除，可在 7 天内从最近删除恢复总结。")
        }
    }
}

private struct SummarySourceDeletionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: DailySummaryItem
    let sourceCount: Int
    let onConfirm: (MemoryDeletionReason, Bool) -> Void
    @State private var reason: MemoryDeletionReason = .noLongerNeeded
    @State private var suppressSimilar = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash.slash.fill")
                    .font(.title2)
                    .foregroundStyle(RecallPalette.warning)
                    .frame(width: 48, height: 48)
                    .background(RecallPalette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("删除内容和原始记录？")
                        .font(.title2.weight(.semibold))
                    Text(item.title)
                        .foregroundStyle(RecallPalette.secondary)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("本次会删除 \(sourceCount) 条来源记录", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Text("相关内容会退出时间线、搜索、问一问和派生提醒，并在“最近删除”中保留 7 天。")
                    .foregroundStyle(RecallPalette.secondary)
            }
            .padding(16)
            .background(RecallPalette.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))

            Picker("为什么删除（仅用于本机整理）", selection: $reason) {
                ForEach(MemoryDeletionReason.allCases) { Text($0.title).tag($0) }
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("以后不再记录类似内容", isOn: $suppressSimilar)
                Text("可选。它只影响之后的新采集，不会改变本次删除的内容和范围；过滤规则可在“设置”中移除。")
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
            }

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("删除内容和原始记录", role: .destructive) {
                    onConfirm(reason, suppressSimilar)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(26)
        .frame(width: 590)
    }
}

private struct SummaryItemSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: DailySummaryItem
    let captures: [CaptureRecord]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("记忆来源").font(.title2.weight(.semibold))
                    Text(item.title).foregroundStyle(RecallPalette.secondary).lineLimit(2)
                }
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding(22)
            Divider()
            if captures.isEmpty {
                ContentUnavailableView("来源已不可用", systemImage: "link.badge.plus", description: Text("这可能是旧总结，或关联记录已经被删除。"))
            } else {
                List(captures.sorted { $0.createdAt > $1.createdAt }) { capture in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(capture.sourceAppName ?? capture.eventTemplate.title).font(.headline)
                            Spacer()
                            Text(capture.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(RecallPalette.secondary)
                        }
                        Text(capture.summary ?? capture.ocrText)
                            .font(.system(size: 15))
                            .foregroundStyle(RecallPalette.secondary)
                            .lineLimit(5)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(RecallPalette.background)
            }
        }
        .frame(width: 680, height: 520)
    }
}

private struct DailyBriefingView: View {
    let briefing: DailyBriefing
    let feedback: [UUID: InsightFeedbackRating]
    let routineStates: [UUID: LearnedRoutineStatus]
    let onReviewInsight: (PersonalInsight, InsightFeedbackRating) -> Void
    let onUpdateRoutine: (LearnedRoutine, LearnedRoutineStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "scope")
                    .font(.title2)
                    .foregroundStyle(RecallPalette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("当天进展").font(.caption.weight(.semibold)).foregroundStyle(RecallPalette.secondary)
                    Text(clean(briefing.headline)).font(.system(size: 15, weight: .semibold))
                }
            }
            if !briefing.progress.isEmpty {
                briefingSection("具体进展", icon: "checkmark.seal.fill", color: RecallPalette.accent, items: briefing.progress, empty: "")
            }
            if !actionItems.isEmpty {
                briefingSection("接下来要处理", icon: "checklist", color: RecallPalette.warning, items: actionItems, empty: "")
            }

            let visibleInsights = briefing.insights.filter { $0.confidence >= 0.75 }
            if !visibleInsights.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("值得留意", icon: "sparkles", color: RecallPalette.accent)
                    ForEach(visibleInsights) { insight in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(clean(insight.title))
                                .font(.system(size: 15, weight: .semibold))
                            Text(clean(insight.detail)).font(.system(size: 15)).foregroundStyle(RecallPalette.secondary)
                            if let recommendation = insight.recommendation {
                                Label(clean(recommendation), systemImage: "arrow.right.circle.fill")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(RecallPalette.accent)
                            }
                            insightFeedbackControls(insight)
                        }
                        .padding(12)
                        .background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            routineReview
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func briefingSection(_ title: String, icon: String, color: Color, items: [BriefingItem], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title, icon: icon, color: color)
            if items.isEmpty {
                Text(empty).font(.system(size: 15)).foregroundStyle(RecallPalette.secondary)
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(clean(item.title)).font(.system(size: 15, weight: .semibold))
                        Text(clean(item.detail)).font(.system(size: 15)).foregroundStyle(RecallPalette.secondary)
                    }
                    .padding(.leading, 2)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
    }

    private var actionItems: [BriefingItem] {
        var seen: Set<String> = []
        return (briefing.openLoops + briefing.nextActions).filter { item in
            let key = "\(item.title)\(item.detail)"
                .replacingOccurrences(of: #"[\s\p{P}\p{S}]+"#, with: "", options: .regularExpression)
                .lowercased()
            return seen.insert(key).inserted
        }
    }

    @ViewBuilder
    private func insightFeedbackControls(_ insight: PersonalInsight) -> some View {
        if let rating = feedback[insight.id] {
            Label(feedbackTitle(rating), systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(RecallPalette.secondary)
        } else {
            HStack(spacing: 14) {
                Text("这个判断准确吗？").font(.caption).foregroundStyle(RecallPalette.secondary)
                Button("准确") { onReviewInsight(insight, .accurate) }
                Button("部分准确") { onReviewInsight(insight, .partiallyAccurate) }
                Button("不准确") { onReviewInsight(insight, .inaccurate) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    @ViewBuilder
    private var routineReview: some View {
        if !briefing.routineCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("可学习的个人规则", icon: "wand.and.stars", color: RecallPalette.accent)
                ForEach(briefing.routineCandidates) { routine in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(clean(routine.title)).font(.system(size: 15, weight: .semibold))
                            Text(clean("\(routine.trigger)，\(routine.suggestedAction)")).font(.system(size: 15)).foregroundStyle(RecallPalette.secondary)
                        }
                        Spacer()
                        let status = routineStates[routine.id] ?? routine.status
                        if status == .proposed {
                            Button("启用") { onUpdateRoutine(routine, .enabled) }
                            Button("忽略") { onUpdateRoutine(routine, .dismissed) }
                        } else {
                            Text(status == .enabled ? "已启用" : "已忽略").font(.caption).foregroundStyle(RecallPalette.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(12)
            .background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func feedbackTitle(_ rating: InsightFeedbackRating) -> String {
        switch rating {
        case .accurate: "已反馈：准确"
        case .partiallyAccurate: "已反馈：部分准确"
        case .inaccurate: "已反馈：不准确"
        case .acted: "已反馈：已采取行动"
        case .dismissed: "已忽略"
        }
    }

    private func clean(_ text: String) -> String {
        DailySummaryContentFormatter.removingCitationMarkers(from: text)
    }
}

struct MarkdownDocumentView: View {
    private enum Block {
        case heading(level: Int, text: String)
        case unorderedList(text: String)
        case orderedList(marker: String, text: String)
        case divider
        case paragraph(text: String)
        case spacer
    }

    let markdown: String

    private var blocks: [Block] {
        markdown
            .components(separatedBy: .newlines)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return .spacer }
                if trimmed == "---" || trimmed == "***" || trimmed == "___" { return .divider }
                if trimmed.hasPrefix("### ") { return .heading(level: 3, text: String(trimmed.dropFirst(4))) }
                if trimmed.hasPrefix("## ") { return .heading(level: 2, text: String(trimmed.dropFirst(3))) }
                if trimmed.hasPrefix("# ") { return .heading(level: 1, text: String(trimmed.dropFirst(2))) }
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                    return .unorderedList(text: String(trimmed.dropFirst(2)))
                }
                if let ordered = orderedListParts(from: trimmed) {
                    return .orderedList(marker: ordered.marker, text: ordered.text)
                }
                return .paragraph(text: trimmed)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, text):
                    inlineText(text)
                        .font(headingFont(for: level))
                        .padding(.top, level == 1 ? 8 : 4)
                case let .unorderedList(text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(.system(size: 15, weight: .bold))
                        inlineText(text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 4)
                case let .orderedList(marker, text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).font(.system(size: 15, weight: .semibold)).foregroundStyle(RecallPalette.secondary)
                        inlineText(text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 4)
                case .divider:
                    Divider().padding(.vertical, 4)
                case let .paragraph(text):
                    inlineText(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .spacer:
                    Spacer().frame(height: 4)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func inlineText(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let attributed = try? AttributedString(markdown: text, options: options) else {
            return Text(text).font(.system(size: 15))
        }
        return Text(attributed).font(.system(size: 15))
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.bold)
        default: .system(size: 15, weight: .semibold)
        }
    }

    private func orderedListParts(from line: String) -> (marker: String, text: String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let markerDigits = line[..<dot]
        guard !markerDigits.isEmpty, markerDigits.allSatisfy(\.isNumber) else { return nil }
        let contentStart = line.index(after: dot)
        guard contentStart < line.endIndex, line[contentStart] == " " else { return nil }
        let textStart = line.index(after: contentStart)
        return (marker: "\(markerDigits).", text: String(line[textStart...]))
    }
}

private struct RemindersView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var reminderBeingScheduled: ReminderCandidate?
    @State private var reminderShowingSources: ReminderCandidate?
    @State private var isCreatingReminder = false
    @State private var isConfirmingDismissAll = false
    @State private var reminderTab = 0
    @State private var historyFilter = 0
    @State private var proposedPage = 1
    @State private var scheduledPage = 1
    @State private var completedPage = 1
    private let pageSize = 6

    private var proposed: [ReminderCandidate] {
        model.state.reminders
            .filter { $0.status == .proposed }
            .sorted {
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture)
            }
    }

    private var scheduled: [ReminderCandidate] {
        model.state.reminders
            .filter { $0.status == .scheduled || $0.status == .snoozed }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
    }

    private var overdue: [ReminderCandidate] {
        scheduled.filter { ($0.dueAt ?? .distantFuture) < .now }
    }

    private var today: [ReminderCandidate] {
        scheduled.filter { reminder in
            guard let dueAt = reminder.dueAt else { return false }
            return dueAt >= .now && Calendar.current.isDateInToday(dueAt)
        }
    }

    private var upcoming: [ReminderCandidate] {
        scheduled.filter { reminder in
            guard let dueAt = reminder.dueAt else { return true }
            return dueAt >= .now && !Calendar.current.isDateInToday(dueAt)
        }
    }

    private var completed: [ReminderCandidate] {
        model.state.reminders
            .filter { (historyFilter == 0 && [.completed, .cancelled, .dismissed].contains($0.status)) || (historyFilter == 1 && $0.status == .completed) || (historyFilter == 2 && ($0.status == .cancelled || $0.status == .dismissed)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var isDiscovering: Bool {
        if case .searching = model.reminderDiscoveryStatus { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            reminderHeader
            HStack(spacing: 24) {
                reminderTabButton("待处理", count: scheduled.count, tab: 0)
                reminderTabButton("待确认", count: proposed.count, tab: 1)
                reminderTabButton("历史", count: model.state.reminders.filter { [.completed, .cancelled, .dismissed].contains($0.status) }.count, tab: 2)
                Spacer()
            }.padding(.horizontal, 24)
            Divider()
            ScrollView {
            VStack(spacing: 20) {
                if reminderTab == 2 {
                    Picker("历史状态", selection: $historyFilter) { Text("全部").tag(0); Text("已完成").tag(1); Text("已取消与忽略").tag(2) }.pickerStyle(.segmented)
                }
                if (reminderTab == 0 && scheduled.isEmpty) || (reminderTab == 1 && proposed.isEmpty) || (reminderTab == 2 && completed.isEmpty) {
                    VStack(spacing: 16) {
                        Image(systemName: "bell").font(.system(size: 38, weight: .light)).foregroundStyle(RecallPalette.accent)
                        Text(reminderTab == 0 ? "暂时没有待处理的提醒" : (reminderTab == 1 ? "没有需要确认的待办" : "还没有历史记录")).font(.headline)
                        Text("从记录中发现的事项会先进入‘待确认’，安排时间后才通知。")
                            .font(.callout).foregroundStyle(RecallPalette.secondary).multilineTextAlignment(.center)
                        HStack(spacing: 12) {
                            Button("新建提醒") { isCreatingReminder = true }.buttonStyle(.borderedProminent)
                            if reminderTab != 1 && !proposed.isEmpty {
                                Button("去看待确认（\(proposed.count)）") { reminderTab = 1 }
                            } else {
                                Button("发现待办") { model.proposeReminders() }.disabled(isDiscovering)
                            }
                        }
                    }.frame(maxWidth: .infinity, minHeight: 400)
                } else { reminderLists }

            }
            .frame(maxWidth: 1_100)
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
            reminderDiscoveryFeedback.padding(.horizontal, 24).padding(.vertical, 12)
        }
        .background(RecallPalette.background)
        .onAppear { openRequestedReminder() }
        .onChange(of: model.navigationRevision) { _, _ in openRequestedReminder() }
        .sheet(item: $reminderBeingScheduled) { reminder in
            ReminderScheduleSheet(
                reminder: reminder,
                preferredHour: model.state.reminderLearningProfile.preferredHour
            ) { dueAt, recurrence in
                model.approveReminder(reminder, dueAt: dueAt, recurrence: recurrence)
            }
        }
        .sheet(isPresented: $isCreatingReminder) {
            NewReminderSheet(preferredHour: model.state.reminderLearningProfile.preferredHour) { title, detail, dueAt, recurrence in
                model.createReminder(title: title, detail: detail, dueAt: dueAt, recurrence: recurrence)
            }
        }
        .sheet(item: $reminderShowingSources) { reminder in
            ReminderSourceSheet(
                reminder: reminder,
                captures: model.state.captures.filter { reminder.sourceCaptureIDs.contains($0.id) }
            )
        }
        .onChange(of: proposed.count) { _, count in proposedPage = clampedPage(proposedPage, itemCount: count) }
        .onChange(of: scheduled.count) { _, count in scheduledPage = clampedPage(scheduledPage, itemCount: count) }
        .onChange(of: completed.count) { _, count in completedPage = clampedPage(completedPage, itemCount: count) }
        .confirmationDialog(
            "忽略全部待确认提醒？",
            isPresented: $isConfirmingDismissAll,
            titleVisibility: .visible
        ) {
            Button("忽略 \(proposed.count) 项提醒", role: .destructive) {
                model.dismissAllProposedReminders()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这些候选会标记为已忽略，不会创建或取消已安排的 macOS 通知。")
        }
    }

    private func reminderTabButton(_ title: String, count: Int, tab: Int) -> some View {
        Button { reminderTab = tab } label: {
            Text(title + " \(count)").font(.system(size: 14, weight: reminderTab == tab ? .semibold : .regular))
                .foregroundStyle(reminderTab == tab ? RecallPalette.accent : RecallPalette.secondary)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { if reminderTab == tab { Rectangle().fill(RecallPalette.accent).frame(height: 2) } }
        }.buttonStyle(.plain)
    }
    private func openRequestedReminder() {
        if case .reminder(let id) = model.destination, let row = model.state.reminders.first(where: { $0.id == id }) {
            reminderTab = row.status == .proposed ? 1 : ([.completed, .cancelled, .dismissed].contains(row.status) ? 2 : 0)
            proposedPage = max(1, ((proposed.firstIndex { $0.id == id } ?? 0) / pageSize) + 1)
            scheduledPage = max(1, ((scheduled.firstIndex { $0.id == id } ?? 0) / pageSize) + 1)
            completedPage = max(1, ((completed.firstIndex { $0.id == id } ?? 0) / pageSize) + 1)
        }
    }
    private var reminderHeader: some View {
        RecallPageHeader(title: "提醒", subtitle: "把需要跟进的事，放到合适的时间") {
            HStack(spacing: 12) {
                Button(isDiscovering ? "正在发现…" : "发现待办") { model.proposeReminders() }.disabled(isDiscovering)
                Button("新建提醒") { isCreatingReminder = true }.buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var reminderDiscoveryFeedback: some View {
        switch model.reminderDiscoveryStatus {
        case .idle:
            EmptyView()
        case let .searching(eligibleRecordCount, analyzingRecordCount):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在分析 \(analyzingRecordCount) 条新增记录，共有 \(eligibleRecordCount) 条记忆参与提醒…")
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 14))
        case let .completed(eligibleRecordCount, analyzedRecordCount, discoveredCount, completedAt):
            HStack(spacing: 10) {
                Text(discoveredCount > 0 ? "新增 \(discoveredCount) 项待确认" : "已检查待办")
                Text("· 最近 " + completedAt.formatted(date: .omitted, time: .shortened))
                Menu("查看检查详情") {
                    Text("本次检查 \(analyzedRecordCount) 条新增或变化记录")
                    Text("共有 \(eligibleRecordCount) 条记录参与发现")
                    if discoveredCount > 0 { Button("查看新增候选") { reminderTab = 1 } }
                }.menuStyle(.borderlessButton).fixedSize()
            }.font(.caption).foregroundStyle(RecallPalette.secondary).frame(maxWidth: .infinity)

        }
    }

    @ViewBuilder
    private var reminderLists: some View {
        VStack(alignment: .leading, spacing: 22) {
            if reminderTab == 0 && !scheduled.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(overdue.isEmpty && today.isEmpty ? "接下来" : "现在需要处理")
                            .font(.title3.weight(.semibold))
                        Text("\(scheduled.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(overdue.isEmpty ? RecallPalette.accent : RecallPalette.danger)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background((overdue.isEmpty ? RecallPalette.accent : RecallPalette.danger).opacity(0.12), in: Capsule())
                        Spacer()
                        if !overdue.isEmpty {
                            Label("\(overdue.count) 项已过期", systemImage: "exclamationmark.circle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(RecallPalette.danger)
                        }
                    }
                    let rows = paged(scheduled, page: scheduledPage)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, reminder in
                        if index == 0 || timeGroup(rows[index - 1]) != timeGroup(reminder) {
                            Text(timeGroup(reminder)).font(.headline).foregroundStyle(RecallPalette.secondary).padding(.top, 8)
                        }
                        reminderCard(reminder, deliveryState: model.reminderDeliveryStates[reminder.id])
                    }
                    ReminderPagination(page: $scheduledPage, itemCount: scheduled.count, pageSize: pageSize)
                }
            }
            if reminderTab == 1 && !proposed.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("待你确认")
                            .font(.title3.weight(.semibold))
                        Text("\(proposed.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RecallPalette.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(RecallPalette.selected, in: Capsule())
                        Spacer()
                        Button("全部忽略", role: .destructive) {
                            isConfirmingDismissAll = true
                        }
                        .buttonStyle(.bordered)
                    }
                    ForEach(paged(proposed, page: proposedPage)) { reminder in
                        reminderCard(reminder, deliveryState: nil)
                    }
                    ReminderPagination(page: $proposedPage, itemCount: proposed.count, pageSize: pageSize)
                }
            }
            if reminderTab == 2 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("历史记录")
                            .font(.title3.weight(.semibold))
                        Text("\(completed.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RecallPalette.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(RecallPalette.sidebar, in: Capsule())
                        Spacer()
                    }
                    ForEach(paged(completed, page: completedPage)) { reminder in
                        reminderCard(reminder, deliveryState: nil)
                    }
                    ReminderPagination(page: $completedPage, itemCount: completed.count, pageSize: pageSize)
                }
            }
        }
    }

    private func timeGroup(_ reminder: ReminderCandidate) -> String {
        guard let due = reminder.dueAt else { return "以后" }
        if due < .now { return "已逾期" }
        return Calendar.current.isDateInToday(due) ? "今天" : "以后"
    }
    private func reminderCard(_ reminder: ReminderCandidate, deliveryState: ReminderDeliveryState?) -> some View {
        ReminderCandidateCard(
            reminder: reminder,
            deliveryState: deliveryState,
            schedule: { reminderBeingScheduled = reminder },
            complete: { model.completeReminder(reminder) },
            snooze: { date in model.snoozeReminder(reminder, until: date) },
            dismiss: { model.dismissReminder(reminder) },
            remove: { model.removeReminder(reminder) },
            viewSources: { reminderShowingSources = reminder },
            preferredHour: model.state.reminderLearningProfile.preferredHour
        )
    }

    private func paged<T>(_ items: [T], page: Int) -> [T] {
        let start = min(max(page - 1, 0) * pageSize, items.count)
        let end = min(start + pageSize, items.count)
        return Array(items[start..<end])
    }

    private func clampedPage(_ page: Int, itemCount: Int) -> Int {
        min(max(page, 1), max(1, Int(ceil(Double(itemCount) / Double(pageSize)))))
    }
}

private struct ReminderMetric: View {
    let title: String
    let value: Int
    let color: Color
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)").font(.title3.weight(.semibold)).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(RecallPalette.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RecallPalette.border, lineWidth: 1))
    }
}

private struct ReminderPagination: View {
    @Binding var page: Int
    let itemCount: Int
    let pageSize: Int

    private var pageCount: Int {
        max(1, Int(ceil(Double(itemCount) / Double(pageSize))))
    }

    var body: some View {
        if pageCount > 1 {
            HStack(spacing: 10) {
                Spacer()
                Button("上一页") { page = max(1, page - 1) }
                    .disabled(page <= 1)
                Text("\(page) / \(pageCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RecallPalette.secondary)
                Button("下一页") { page = min(pageCount, page + 1) }
                    .disabled(page >= pageCount)
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct ReminderWorkflowStep: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(RecallPalette.onAccent)
                .frame(width: 23, height: 23)
                .background(RecallPalette.accent, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReminderEmptyState: View {
    let totalRecordCount: Int
    let eligibleRecordCount: Int
    let lastRunAt: Date?
    let isDiscovering: Bool
    let onCreate: () -> Void
    let onDiscover: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(RecallPalette.accent)
                .frame(width: 58, height: 58)
                .background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 7) {
                Text("今天没有需要处理的提醒")
                    .font(.title3.weight(.semibold))
                Text(discoveryDescription)
                    .font(.subheadline)
                    .foregroundStyle(RecallPalette.secondary)
                if let lastRunAt {
                    Text("上次后台分析：\(lastRunAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                Button(action: onDiscover) {
                    if isDiscovering {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("正在分析")
                        }
                    } else {
                        Label("重新分析", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isDiscovering)
                Button(action: onCreate) {
                    Label("新建提醒", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(RecallPalette.border, lineWidth: 1))
    }

    private var discoveryDescription: String {
        if totalRecordCount > 0, eligibleRecordCount == 0 {
            return "已有 \(totalRecordCount) 条记忆，但当前没有记录类型被允许参与提醒分析。可在“记录管理”中调整范围。"
        }
        return "后台已从 \(eligibleRecordCount) 条可用记忆中检查待办、承诺与截止事项；只有你确认后才会通知。"
    }
}

private struct ReminderFeature: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon).foregroundStyle(RecallPalette.accent)
            Text(title).font(.caption.weight(.semibold))
            Text(detail).font(.caption2).foregroundStyle(RecallPalette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReminderScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let reminder: ReminderCandidate
    let onConfirm: (Date, ReminderRecurrence) -> Void
    @State private var selectedDate: Date
    @State private var recurrence: ReminderRecurrence

    init(reminder: ReminderCandidate, preferredHour: Int, onConfirm: @escaping (Date, ReminderRecurrence) -> Void) {
        self.reminder = reminder
        self.onConfirm = onConfirm
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now.addingTimeInterval(24 * 60 * 60)
        let fallback = calendar.date(bySettingHour: preferredHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        let earliest = Date.now.addingTimeInterval(60)
        _selectedDate = State(initialValue: max(reminder.dueAt ?? fallback, earliest))
        _recurrence = State(initialValue: reminder.recurrence)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(reminder.status == .scheduled || reminder.status == .snoozed ? "修改提醒时间" : "设置提醒时间")
                    .font(.title2.weight(.semibold))
                Text(reminder.title)
                    .font(.subheadline)
                    .foregroundStyle(RecallPalette.secondary)
                    .lineLimit(2)
                if reminder.status == .scheduled || reminder.status == .snoozed, let currentDate = reminder.dueAt {
                    Text("当前安排：\(currentDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(RecallPalette.accent)
                } else if let suggestedDate = reminder.dueAt {
                    Text("已根据记录中的时间线索预填建议时间，你可以直接修改。")
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                    Text("建议：\(suggestedDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(RecallPalette.accent)
                } else {
                    Text("记录中没有明确时间；已预填明天上午 9:00，请按需要调整。")
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                }
            }

            DatePicker(
                "提醒时间",
                selection: $selectedDate,
                in: Date.now...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.field)

            Picker("重复", selection: $recurrence) {
                ForEach(ReminderRecurrence.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("创建后仍可在“已安排”中取消提醒。")
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button(reminder.status == .scheduled || reminder.status == .snoozed ? "保存修改" : "确认并创建") {
                    onConfirm(selectedDate, recurrence)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedDate <= Date.now)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

private struct NewReminderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (String, String, Date, ReminderRecurrence) -> Void
    @State private var title = ""
    @State private var detail = ""
    @State private var dueAt: Date
    @State private var recurrence: ReminderRecurrence = .none

    init(preferredHour: Int, onCreate: @escaping (String, String, Date, ReminderRecurrence) -> Void) {
        self.onCreate = onCreate
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now.addingTimeInterval(86_400)
        _dueAt = State(initialValue: Calendar.current.date(bySettingHour: preferredHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("新建提醒").font(.title2.weight(.semibold))
                Text("直接创建你已经确认的事项，不需要先经过记忆识别。")
                    .font(.subheadline).foregroundStyle(RecallPalette.secondary)
            }
            TextField("要提醒什么", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 16))
            TextField("补充说明（可选）", text: $detail, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            DatePicker("提醒时间", selection: $dueAt, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.field)
            Picker("重复", selection: $recurrence) {
                ForEach(ReminderRecurrence.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("创建提醒") {
                    onCreate(title, detail, dueAt, recurrence)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dueAt <= .now)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

private struct ReminderSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let reminder: ReminderCandidate
    let captures: [CaptureRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("提醒来源")
                        .font(.title2.weight(.semibold))
                    Text(reminder.title)
                        .font(.subheadline)
                        .foregroundStyle(RecallPalette.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
            }

            if captures.isEmpty {
                ContentUnavailableView(
                    "来源记录已不存在",
                    systemImage: "doc.questionmark",
                    description: Text("对应记录可能已被删除或超过了保留期限。")
                )
            } else {
                List(captures.sorted(by: { $0.createdAt > $1.createdAt })) { capture in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(capture.sourceAppName ?? capture.eventTemplate.title)
                                .font(.headline)
                            Spacer()
                            Text(capture.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(RecallPalette.secondary)
                        }
                        Text(capture.summary ?? capture.ocrText)
                            .font(.subheadline)
                            .textSelection(.enabled)
                            .lineLimit(8)
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(RecallPalette.background)
            }
        }
        .padding(24)
        .frame(width: 680, height: 480)
    }
}

private struct ReminderCandidateCard: View {
    let reminder: ReminderCandidate
    let deliveryState: ReminderDeliveryState?
    let schedule: () -> Void
    let complete: () -> Void
    let snooze: (Date) -> Void
    let dismiss: () -> Void
    let remove: () -> Void
    let viewSources: () -> Void
    let preferredHour: Int

    private var isActive: Bool {
        reminder.status == .scheduled || reminder.status == .snoozed
    }

    private var isOverdue: Bool {
        isActive && (reminder.dueAt ?? .distantFuture) < .now
    }

    private var statusColor: Color {
        switch reminder.status {
        case .proposed: RecallPalette.warning
        case .scheduled, .snoozed: isOverdue ? RecallPalette.danger : .accentColor
        case .completed: RecallPalette.accent
        case .dismissed, .cancelled: RecallPalette.secondary
        }
    }

    private var statusIcon: String {
        switch reminder.status {
        case .proposed: "bell.badge"
        case .scheduled: isOverdue ? "exclamationmark.bell.fill" : "bell.fill"
        case .snoozed: "clock.badge"
        case .completed: "checkmark.circle.fill"
        case .dismissed, .cancelled: "bell.slash"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 36, height: 36)
                .background(statusColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(reminder.title).font(.headline)
                if !reminder.detail.isEmpty {
                    Text(reminder.detail)
                        .font(.subheadline)
                        .foregroundStyle(RecallPalette.secondary)
                        .lineLimit(3)
                }
                HStack(spacing: 10) {
                    if !reminder.sourceCaptureIDs.isEmpty {
                        Button(action: viewSources) {
                            Label("\(reminder.sourceCaptureIDs.count) 条来源", systemImage: "link")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(RecallPalette.accent)
                    }
                    if let dueAt = reminder.dueAt {
                        Label(
                            reminder.status == .proposed ? "建议：\(dueAt.formatted(date: .abbreviated, time: .shortened))" : dueAt.formatted(date: .abbreviated, time: .shortened),
                            systemImage: "calendar"
                        )
                    } else if reminder.status == .proposed {
                        Label("创建前选择时间", systemImage: "calendar.badge.clock")
                    }
                    if reminder.status == .proposed {
                        Text(reminder.confidence >= 0.8 ? "线索明确" : "请核对")
                    }
                    if reminder.recurrence != .none {
                        Label(reminder.recurrence.title, systemImage: "repeat")
                    }
                    Text(reminder.origin.title)
                }
                .font(.caption)
                .foregroundStyle(RecallPalette.secondary)
                if isActive, deliveryState == .notFound, !isOverdue {
                    ReminderDeliveryBadge(state: deliveryState)
                } else if reminder.status == .completed {
                    Label("已由你标记完成", systemImage: "checkmark.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(RecallPalette.secondary)
                }
            }
            Spacer()
            if isActive {
                VStack(alignment: .trailing, spacing: 8) {
                    Text(isOverdue ? "已过期" : (reminder.status == .snoozed ? "已稍后" : "已安排"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isOverdue ? RecallPalette.danger : RecallPalette.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background((isOverdue ? RecallPalette.danger : RecallPalette.accent).opacity(0.10), in: Capsule())
                    Button("标记完成", action: complete)
                        .buttonStyle(.borderedProminent)
                        .font(.caption)
                    HStack(spacing: 8) {
                        Menu("稍后") {
                            Button("1 小时后") { snooze(.now.addingTimeInterval(60 * 60)) }
                            Button("明天 \(preferredHour):00") {
                                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now.addingTimeInterval(86_400)
                                snooze(Calendar.current.date(bySettingHour: preferredHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        Button("修改", action: schedule)
                            .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    Button("取消", role: .destructive, action: dismiss).buttonStyle(.borderless).font(.caption)
                }
            } else if reminder.status == .proposed {
                VStack(alignment: .trailing, spacing: 8) {
                    Button("选择时间并创建", action: schedule)
                        .buttonStyle(.borderedProminent)
                    Button("忽略", role: .destructive, action: dismiss)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            } else if reminder.status == .completed || reminder.status == .cancelled {
                VStack(alignment: .trailing, spacing: 8) {
                    Text(reminder.status == .completed ? "已完成" : "已取消")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RecallPalette.secondary)
                    Button("从列表移除", action: remove)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
        .padding(18)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(RecallPalette.border, lineWidth: 1))
    }
}

private struct ReminderDeliveryBadge: View {
    let state: ReminderDeliveryState?

    private var presentation: (text: String, symbol: String, color: Color) {
        switch state {
        case .pending:
            return ("已写入系统通知队列，等待投递", "clock.badge.checkmark", RecallPalette.accent)
        case .delivered:
            return ("已推送到 macOS 通知中心", "checkmark.bubble", RecallPalette.accent)
        case .notFound:
            return ("未在 macOS 通知队列中找到", "exclamationmark.triangle", RecallPalette.warning)
        case .none:
            return ("正在核验 macOS 通知状态", "arrow.triangle.2.circlepath", RecallPalette.secondary)
        }
    }

    var body: some View {
        Label(presentation.text, systemImage: presentation.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(presentation.color)
    }
}

private struct EventRulesView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var selectedID: UUID?
    private var selected: EventRule? { model.state.rules.first { $0.id == selectedID } ?? model.state.rules.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecallPageHeader(title: "记录管理", subtitle: "选择何时记录、记录什么") {
                Button("查看已保存记录") { if let source = model.state.captures.first { model.destination = .record(source.id) } }.disabled(model.state.captures.isEmpty)
            }
            HStack(spacing: 12) {
                RecallStatusBadge(title: "原图保留 " + retention(images: true))
                RecallStatusBadge(title: "文本保留 " + retention(images: false))
                RecallStatusBadge(title: model.state.rules.contains { $0.template == .enterKeyTrigger && $0.isEnabled } ? "裸 Enter 监听已启用" : "裸 Enter 监听关闭", warning: model.state.rules.contains { $0.template == .enterKeyTrigger && $0.isEnabled })
            }.padding(.horizontal, 24).padding(.bottom, 16)
            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.state.rules) { rule in
                            HStack(spacing: 12) {
                                Button { selectedID = rule.id } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(rule.template.title).font(.system(size: 14, weight: .semibold))
                                        Text(rule.template.summary).font(.caption).foregroundStyle(RecallPalette.secondary).lineLimit(2)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Toggle("启用" + rule.template.title, isOn: Binding(get: { model.state.rules.first { $0.id == rule.id }?.isEnabled ?? false }, set: { model.toggleRule(rule, isEnabled: $0) }))
                                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }.padding(14).background(selected?.id == rule.id ? RecallPalette.selected : RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected?.id == rule.id ? RecallPalette.accent : RecallPalette.border, lineWidth: 1))
                        }
                    }
                }.frame(width: 290).clipped()
                ScrollView {
                    if let selected {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(selected.template.title).font(RecallTypography.title)
                            Text(selected.template.summary).font(.callout).foregroundStyle(RecallPalette.secondary)
                            if selected.template == .enterKeyTrigger {
                                Label(model.enterKeyMonitorStatus.title, systemImage: model.enterKeyMonitorStatus.symbolName).font(.caption).foregroundStyle(RecallPalette.warning)
                                Text("仅在 Recall 不在前台时触发；不会拦截按键。需要输入监控、辅助功能和屏幕录制权限。").font(.caption).foregroundStyle(RecallPalette.secondary)
                                Button("检查跨应用权限") { model.checkEnterKeyMonitor() }
                            }
                            EventRuleEditor(rule: selected).id(selected.id)
                        }.recallSurface().padding(.bottom, 24)
                    }
                }.clipped()
            }.padding(.horizontal, 24).padding(.bottom, 16)
        }
    }
    private func retention(images: Bool) -> String {
        let values = model.state.rules.map { images ? $0.retainImageDays : $0.retainTextDays }
        let low = values.min() ?? 0, high = values.max() ?? 0
        return low == high ? "\(low) 天" : "\(low)–\(high) 天"
    }
}

private struct EventRuleRow: View {
    @EnvironmentObject private var model: RecallAppModel
    let rule: EventRule
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(isOn: Binding(
                    get: { model.state.rules.first(where: { $0.id == rule.id })?.isEnabled ?? false },
                    set: { model.toggleRule(rule, isEnabled: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.template.title).font(.headline)
                        Text(rule.template.summary).font(.caption).foregroundStyle(RecallPalette.secondary)
                    }
                }
                Button(expanded ? "收起" : "配置") { expanded.toggle() }
                    .buttonStyle(.borderless)
            }
            if rule.template == .enterKeyTrigger {
                HStack(spacing: 8) {
                    Label(model.enterKeyMonitorStatus.title, systemImage: model.enterKeyMonitorStatus.symbolName)
                        .font(.caption)
                        .foregroundStyle(model.enterKeyMonitorStatus == .monitoring ? RecallPalette.accent : RecallPalette.warning)
                    Spacer()
                    Button("检查跨应用权限") {
                        model.checkEnterKeyMonitor()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                Text("跨应用触发需同时获得“输入监控”和“辅助功能”授权；实际截图仍需屏幕录制权限。监听不拦截按键，且仅在 Recall 不在前台时触发。")
                    .font(.caption2)
                    .foregroundStyle(RecallPalette.secondary)
            }
            if expanded {
                EventRuleEditor(rule: rule)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct EventRuleEditor: View {
    @EnvironmentObject private var model: RecallAppModel
    let rule: EventRule
    @State private var scope: CaptureScope
    @State private var retainImages: Int
    @State private var retainText: Int
    @State private var includeChat: Bool
    @State private var includeReminders: Bool
    @State private var allowList: String

    init(rule: EventRule) {
        self.rule = rule
        _scope = State(initialValue: rule.scope)
        _retainImages = State(initialValue: rule.retainImageDays)
        _retainText = State(initialValue: rule.retainTextDays)
        _includeChat = State(initialValue: rule.participatesInChat)
        _includeReminders = State(initialValue: rule.participatesInReminders)
        _allowList = State(initialValue: rule.appAllowList.joined(separator: ", "))
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("采集范围")
                Picker("采集范围", selection: $scope) {
                    ForEach(CaptureScope.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            GridRow {
                Text("原图保留")
                Stepper("\(retainImages) 天", value: $retainImages, in: 0...365).fixedSize()
            }
            GridRow {
                Text("文本保留")
                Stepper("\(retainText) 天", value: $retainText, in: 1...3650).fixedSize()
            }
            GridRow {
                Text("应用白名单")
                TextField("Bundle ID，以逗号分隔", text: $allowList)
            }
        }
        Divider()
        RecallSwitchRow(title: "问一问可检索这类记录", isOn: $includeChat)
        RecallSwitchRow(title: "从这类记录中发现待办", isOn: $includeReminders)
        Button("保存规则") {
            var updated = model.state.rules.first { $0.id == rule.id } ?? rule
            updated.scope = scope
            updated.retainImageDays = retainImages
            updated.retainTextDays = retainText
            updated.participatesInChat = includeChat
            updated.participatesInReminders = includeReminders
            updated.appAllowList = allowList.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            model.updateRule(updated)
        }
        .buttonStyle(.borderedProminent)
    }
}

private struct RecallDiagnosticsLogSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本地诊断日志")
                        .font(.title2.weight(.semibold))
                    Text("仅包含 Recall 的操作状态与错误代码，不包含 API Key、聊天正文、OCR 文本或截图。")
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding(20)

            Divider()

            if model.diagnosticEntries.isEmpty {
                ContentUnavailableView("暂无诊断记录", systemImage: "stethoscope", description: Text("执行记录、Enter 监听或权限检查后，相关状态会显示在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.diagnosticEntries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Image(systemName: symbol(for: entry.level))
                                .foregroundStyle(color(for: entry.level))
                            Text(entry.level.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(color(for: entry.level))
                            Text(entry.source)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(RecallPalette.secondary)
                            Spacer()
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(RecallPalette.secondary)
                        }
                        Text(entry.message)
                            .font(.subheadline)
                        if !entry.metadata.isEmpty {
                            Text(entry.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(RecallPalette.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(RecallPalette.background)
            }

            Divider()
            HStack {
                Text("最多保留 200 条；仅保存在此 Mac。")
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
                Spacer()
                Button("清空日志", role: .destructive) { model.clearDiagnosticLog() }
            }
            .padding(16)
        }
        .frame(width: 720, height: 560)
    }

    private func color(for level: RecallDiagnosticLevel) -> Color {
        switch level {
        case .info: RecallPalette.secondary
        case .warning: RecallPalette.warning
        case .error: RecallPalette.danger
        }
    }

    private func symbol(for level: RecallDiagnosticLevel) -> String {
        switch level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}

struct RecallSettingsView: View {
    var body: some View {
        PrivacyAndModelView()
            .padding()
    }
}

private struct PrivacyAndModelView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var excludedApps = ""
    @State private var loaded = false
    @State private var savedKeyExists = false
    @State private var activeConfiguration = LLMConfiguration()
    @State private var isEditingModelConnection = false
    @State private var isShowingDiagnostics = false
    @State private var itemPendingPermanentDeletion: RecentlyDeletedMemory?
    @State private var isConfirmingPermanentDeletion = false
    @State private var isConfirmingClearAll = false
    @State private var showsAllRecentlyDeleted = false

    @State private var settingsCategory = "隐私与采集"
    @State private var showsMemorySettings = false
    @State private var showsDiagnosticSettings = false
    @State private var showsGovernance = false
    @State private var showsTime = false
    private let categories = ["隐私与采集", "模型连接", "每日回顾", "记忆整理", "本地诊断"]

    var body: some View {
        VStack(spacing: 0) {
            RecallPageHeader(title: "设置", subtitle: "管理本地数据边界、模型使用和每日回顾") { EmptyView() }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(categories, id: \.self) { value in
                        Button { settingsCategory = value } label: {
                            Text(value).font(.system(size: 14, weight: settingsCategory == value ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11)
                                .foregroundStyle(settingsCategory == value ? RecallPalette.accent : RecallPalette.text)
                                .background(settingsCategory == value ? RecallPalette.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }.frame(width: 126)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            privacyStatus
                            privacyCard.id("隐私与采集")
                            modelCard.id("模型连接")
                            dailyCard.id("每日回顾")
                            DisclosureGroup(isExpanded: $showsMemorySettings) {
                                VStack(alignment: .leading, spacing: 18) {
                                    CaptureUnderstandingSettingsView().environmentObject(model)
                                    Divider()
                                    MemoryOrganizationSettings().environmentObject(model)
                                }.padding(.top, 16)
                            } label: {
                                HStack { Text("记忆整理").fontWeight(.semibold); Spacer(); Text(model.state.memoryKnowledgeSettings.automaticOrganization ? "后台整理已开启" : "后台整理已暂停").font(.caption).foregroundStyle(RecallPalette.secondary) }
                            }.recallSurface().id("记忆整理")
                            DisclosureGroup(isExpanded: $showsDiagnosticSettings) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("仅记录操作结果、权限状态和错误代码，不包含聊天正文、识别文字、截图或密钥。").font(.caption).foregroundStyle(RecallPalette.secondary)
                                    Button("查看日志") { isShowingDiagnostics = true }
                                }.padding(.top, 12)
                            } label: {
                                HStack { Text("本地诊断").fontWeight(.semibold); Spacer(); Text("当前 \(model.diagnosticEntries.count) 条").font(.caption).foregroundStyle(RecallPalette.secondary) }
                            }.recallSurface().id("本地诊断")
                            DisclosureGroup("最近删除与忽略规则", isExpanded: $showsGovernance) { memoryGovernanceSection.padding(.top, 14) }.recallSurface()
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("清空本地记忆").font(.subheadline.weight(.medium))
                                    Text("清空全部内容后无法恢复。").font(.caption).foregroundStyle(RecallPalette.secondary)
                                }
                                Spacer()
                                Button("删除全部本地记忆", role: .destructive) { isConfirmingClearAll = true }
                            }.padding(16)
                        }.padding(.bottom, 24)
                    }.clipped().onChange(of: settingsCategory) { _, category in
                        if category == "记忆整理" { showsMemorySettings = true }
                        if category == "本地诊断" { showsDiagnosticSettings = true }
                        withAnimation { proxy.scrollTo(category, anchor: .top) }
                    }
                }
            }.padding(.horizontal, 24).padding(.bottom, 16)
        }
        .toggleStyle(.switch).controlSize(.small)
        .background(RecallPalette.background)
        .onAppear(perform: load)
        .sheet(isPresented: $isShowingDiagnostics) {
            RecallDiagnosticsLogSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $isEditingModelConnection) {
            ModelConnectionEditorSheet(
                configuration: activeConfiguration,
                savedKeyExists: savedKeyExists
            ) { configuration, key in
                let excluded = model.state.privacy.excludedBundleIdentifiers
                activeConfiguration = configuration
                model.saveModelConnection(configuration: configuration, apiKey: key, excludedBundleIdentifiers: excluded)
                if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    savedKeyExists = true
                }
            }
        }
        .confirmationDialog(
            "永久删除后无法恢复",
            isPresented: $isConfirmingPermanentDeletion,
            presenting: itemPendingPermanentDeletion
        ) { item in
            Button("永久删除“\(item.label)”", role: .destructive) { model.permanentlyDelete(item) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("关联截图和最近删除快照会从这台 Mac 上清除。")
        }
        .confirmationDialog("永久清空全部本地记忆？", isPresented: $isConfirmingClearAll) {
            Button("永久清空", role: .destructive) { model.clearAllData() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("时间线、问一问、总结、提醒、长期记忆、截图、最近删除和忽略规则都会清除，且无法撤销。设置会保留。")
        }
    }

    private var privacyStatus: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { privacyStatusText; Spacer(minLength: 8); pauseButton }
            VStack(alignment: .leading, spacing: 12) { privacyStatusText; pauseButton }
        }.padding(16).background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 12))
    }
    private var privacyStatusText: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(model.state.privacy.screenCapturePaused ? "采集已暂停" : "采集由你控制 · 记录保存在本机", systemImage: model.state.privacy.screenCapturePaused ? "pause.circle" : "lock.shield")
                .font(.subheadline.weight(.medium))
            Text(model.state.privacy.cloudUseEnabled ? "已允许向连接的模型发送脱敏文本" : "云端模型已关闭，文本不外发")
                .font(.caption).foregroundStyle(RecallPalette.secondary)
        }
    }
    private var pauseButton: some View {
        Button(model.state.privacy.screenCapturePaused ? "恢复采集" : "暂停全部采集") {
            var privacy = model.state.privacy; privacy.screenCapturePaused.toggle(); model.updatePrivacy(privacy)
        }.fixedSize()
    }
    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("屏幕与数据").font(.headline).foregroundStyle(RecallPalette.accent)
            RecallSwitchRow(title: "保留原始截图", detail: "按记录管理中设置的周期清理。关闭后仅保留识别文字。", isOn: privacyBinding(\.retainScreenshots))
            Text("排除的应用（不会被采集）").font(.caption).foregroundStyle(RecallPalette.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(model.state.privacy.excludedBundleIdentifiers.sorted(), id: \.self) { id in
                    HStack(spacing: 6) {
                        Text(applicationName(id)).font(.caption).lineLimit(1)
                        Button { var privacy = model.state.privacy; privacy.excludedBundleIdentifiers.remove(id); model.updatePrivacy(privacy) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).accessibilityLabel("不再排除" + applicationName(id))
                    }.padding(.horizontal, 9).padding(.vertical, 7).background(RecallPalette.selected, in: Capsule()).help(id)
                }
                Button("＋ 添加") { addExcludedApplication() }.buttonStyle(.borderless)
            }
            Button("检查屏幕权限") { model.requestScreenRecordingAccess() }.buttonStyle(.plain).font(.caption).foregroundStyle(RecallPalette.accent)
        }.recallSurface()
    }
    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("模型连接").font(.headline).foregroundStyle(RecallPalette.accent)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cpu").foregroundStyle(RecallPalette.accent).frame(width: 36, height: 36).background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.state.llmConfiguration.provider.title).font(.subheadline.weight(.medium))
                    Text(model.state.llmConfiguration.model).font(.caption)
                    Text(model.state.llmConfiguration.baseURLString).font(.caption).foregroundStyle(RecallPalette.secondary).lineLimit(1).textSelection(.enabled)
                    Text(model.state.llmConfiguration.apiKey.isEmpty ? "尚未配置凭据" : "连接已配置 · 凭据仅保存在本机").font(.caption).foregroundStyle(RecallPalette.secondary)
                }
                Spacer(minLength: 0)
                Button("编辑") { activeConfiguration = model.state.llmConfiguration; savedKeyExists = !activeConfiguration.apiKey.isEmpty; isEditingModelConnection = true }
            }
            RecallSwitchRow(title: "允许发送脱敏文本", detail: "关闭后，问一问使用本地摘录；模型回顾和自动理解会暂停。", isOn: privacyBinding(\.cloudUseEnabled))
        }.recallSurface()
    }
    private var dailyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("每日回顾").font(.headline).foregroundStyle(RecallPalette.accent)
            RecallSwitchRow(title: "每天自动汇总前一天", detail: "只回顾已保存的记录，需连接模型并允许发送脱敏文本。", isOn: dailySummaryEnabledBinding)
            HStack {
                Text("生成时间").font(.subheadline)
                Spacer()
                Button(String(format: "每天 %02d:%02d ▾", model.state.dailySummarySettings.hour, model.state.dailySummarySettings.minute)) { showsTime = true }
                    .popover(isPresented: $showsTime) {
                        VStack(alignment: .leading, spacing: 16) {
                            DatePicker("每天生成时间", selection: dailySummaryTimeBinding, displayedComponents: .hourAndMinute).datePickerStyle(.field)
                            Button("完成") { showsTime = false }
                        }.padding(20)
                    }.disabled(!model.state.dailySummarySettings.isEnabled)
            }
            RecallSwitchRow(title: "完成后发送系统通知", detail: "主动开启后才请求通知权限。", isOn: dailySummaryNotificationBinding).disabled(!model.state.dailySummarySettings.isEnabled)
        }.recallSurface()
    }
    private func applicationName(_ id: String) -> String {
        let known = ["com.apple.MobileSMS": "信息", "com.apple.Passwords": "密码", "com.apple.keychainaccess": "钥匙串访问"]
        if let name = known[id] { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url.deletingPathExtension().lastPathComponent }
        return id.split(separator: ".").last.map(String.init) ?? id
    }
    private func addExcludedApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.allowsMultipleSelection = true
        panel.prompt = "排除这些应用"
        guard panel.runModal() == .OK else { return }
        var privacy = model.state.privacy
        for url in panel.urls { if let id = Bundle(url: url)?.bundleIdentifier { privacy.excludedBundleIdentifiers.insert(id) } }
        model.updatePrivacy(privacy)
    }

    private var memoryGovernanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("记忆治理", systemImage: "trash.slash")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("最近删除保留 \(MemoryGovernance.retentionDays) 天")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(RecallPalette.secondary)
            }
            Text("删除的内容会立即退出搜索、问一问、总结和派生提醒；7 天内可恢复。到期时运行中的应用会自动清理，应用关闭时将在下次启动后清理。忽略规则只保存在本机，并在采集时生效。")
                .font(.subheadline)
                .foregroundStyle(RecallPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.state.recentlyDeletedMemories.isEmpty && model.state.memorySuppressionRules.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(RecallPalette.accent)
                    Text("暂无最近删除内容或忽略规则。")
                        .font(.subheadline)
                        .foregroundStyle(RecallPalette.secondary)
                }
                .padding(.vertical, 4)
            } else {
                if !model.state.recentlyDeletedMemories.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("最近删除").font(.headline)
                            Text("\(model.state.recentlyDeletedMemories.count) 条")
                                .font(.caption).foregroundStyle(RecallPalette.secondary)
                            Spacer()
                            if model.state.recentlyDeletedMemories.count > 8 {
                                Button(showsAllRecentlyDeleted ? "收起" : "查看全部") {
                                    showsAllRecentlyDeleted.toggle()
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        LazyVStack(spacing: 10) {
                            ForEach(model.state.recentlyDeletedMemories
                                .sorted { $0.deletedAt > $1.deletedAt }
                                .prefix(showsAllRecentlyDeleted ? model.state.recentlyDeletedMemories.count : 8)) { item in
                                HStack(spacing: 12) {
                                    Image(systemName: "trash.circle")
                                        .foregroundStyle(RecallPalette.warning)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.label).font(.subheadline.weight(.medium)).lineLimit(1)
                                        Text(item.reason.title)
                                            .font(.caption).foregroundStyle(RecallPalette.secondary)
                                        Text(item.expiresAt <= .now
                                             ? "已到期，等待永久清理"
                                             : "将于 \(item.expiresAt.formatted(date: .abbreviated, time: .shortened)) 永久删除")
                                            .font(.caption).foregroundStyle(RecallPalette.secondary)
                                    }
                                    Spacer()
                                    Button("恢复") { model.restoreRecentlyDeleted(item) }
                                        .buttonStyle(.bordered)
                                        .disabled(item.expiresAt <= .now)
                                    Button("永久删除", role: .destructive) {
                                        itemPendingPermanentDeletion = item
                                        isConfirmingPermanentDeletion = true
                                    }
                                        .buttonStyle(.borderless)
                                }
                                .padding(12)
                                .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }

                if !model.state.memorySuppressionRules.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("以后忽略").font(.headline)
                        ForEach(model.state.memorySuppressionRules.filter(\.isEnabled).prefix(8)) { rule in
                            HStack(spacing: 12) {
                                Image(systemName: "nosign").foregroundStyle(RecallPalette.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rule.phrase).font(.subheadline).lineLimit(1)
                                    Text(rule.reason.title).font(.caption).foregroundStyle(RecallPalette.secondary)
                                }
                                Spacer()
                                Button("删除规则", role: .destructive) { model.removeSuppressionRule(rule) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RecallPalette.border, lineWidth: 1))
    }

    private var settingsHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(RecallPalette.onAccent)
                .frame(width: 50, height: 50)
                .background(RecallPalette.accent, in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 5) {
                Text("设置")
                    .font(.system(size: 26, weight: .semibold))
                Text("统一管理本地数据边界、模型使用和每日回顾。")
                    .font(.subheadline)
                    .foregroundStyle(RecallPalette.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Label(model.state.privacy.screenCapturePaused ? "采集已暂停" : "本地数据保护中", systemImage: model.state.privacy.screenCapturePaused ? "pause.circle.fill" : "lock.fill")
                Label(model.state.privacy.cloudUseEnabled ? "已允许脱敏文本" : "仅本地模式", systemImage: model.state.privacy.cloudUseEnabled ? "cloud.fill" : "desktopcomputer")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(RecallPalette.secondary)
        }
        .padding(20)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RecallPalette.border, lineWidth: 1))
    }

    private func settingsCard<Content: View>(title: String, icon: String, tint: Color = .accentColor, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(tint)
            content()
        }
        .padding(20)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RecallPalette.border, lineWidth: 1))
    }

    private func load() {
        guard !loaded else { return }
        let savedConfiguration = model.state.llmConfiguration
        activeConfiguration = savedConfiguration
        excludedApps = model.state.privacy.excludedBundleIdentifiers.sorted().joined(separator: ", ")
        savedKeyExists = !savedConfiguration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        loaded = true
    }


    private var dailySummaryEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.state.dailySummarySettings.isEnabled },
            set: { value in
                var settings = model.state.dailySummarySettings
                settings.isEnabled = value
                model.updateDailySummarySettings(settings)
            }
        )
    }

    private var dailySummaryTimeBinding: Binding<Date> {
        Binding(
            get: {
                let settings = model.state.dailySummarySettings
                return Calendar.current.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: .now) ?? .now
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                var settings = model.state.dailySummarySettings
                settings.hour = components.hour ?? settings.hour
                settings.minute = components.minute ?? settings.minute
                model.updateDailySummarySettings(settings)
            }
        )
    }

    private var dailySummaryNotificationBinding: Binding<Bool> {
        Binding(
            get: { model.state.dailySummarySettings.notifyWhenReady ?? false },
            set: { value in
                var settings = model.state.dailySummarySettings
                settings.notifyWhenReady = value
                model.updateDailySummarySettings(settings)
            }
        )
    }

    private func privacyBinding(_ keyPath: WritableKeyPath<PrivacySettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.state.privacy[keyPath: keyPath] },
            set: { value in
                var privacy = model.state.privacy
                privacy[keyPath: keyPath] = value
                model.updatePrivacy(privacy)
            }
        )
    }
}


private struct ModelConnectionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialConfiguration: LLMConfiguration
    let savedKeyExists: Bool
    let onSave: (LLMConfiguration, String) -> Void

    @State private var provider: LLMProviderKind
    @State private var baseURL: String
    @State private var modelName: String
    @State private var apiKey = ""
    @State private var revealsAPIKey = false
    @State private var isTestingConnection = false
    @State private var connectionStatus: ConnectionStatus?
    @FocusState private var focusedField: Field?

    private enum ConnectionStatus {
        case success(String)
        case failure(String)
    }

    private enum Field: Hashable {
        case baseURL, model, apiKey
    }

    init(configuration: LLMConfiguration, savedKeyExists: Bool, onSave: @escaping (LLMConfiguration, String) -> Void) {
        initialConfiguration = configuration
        self.savedKeyExists = savedKeyExists
        self.onSave = onSave
        _provider = State(initialValue: configuration.provider == .anthropicCompatible ? .anthropicCompatible : .openAICompatible)
        _baseURL = State(initialValue: configuration.baseURLString)
        _modelName = State(initialValue: configuration.model)
        // 已保存的 Key 不回填到可见输入框，避免录屏或截图暴露完整凭据。
        _apiKey = State(initialValue: "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(RecallPalette.onAccent)
                    .frame(width: 44, height: 44)
                    .background(RecallPalette.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("编辑模型连接").font(.title2.weight(.semibold))
                    Text("配置与 OpenAI 或 Anthropic 协议兼容的模型服务")
                        .font(.subheadline)
                        .foregroundStyle(RecallPalette.secondary)
                }
                Spacer()
                Label(savedKeyExists ? "凭据已配置" : "等待配置", systemImage: savedKeyExists ? "checkmark.shield.fill" : "key.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(savedKeyExists ? RecallPalette.accent : RecallPalette.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background((savedKeyExists ? RecallPalette.accent : RecallPalette.warning).opacity(0.10), in: Capsule())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("接口协议", detail: "选择服务端兼容的请求格式")
                        Picker("模型类型", selection: $provider) {
                            Text("兼容 OpenAI API").tag(LLMProviderKind.openAICompatible)
                            Text("兼容 Anthropic API").tag(LLMProviderKind.anthropicCompatible)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .padding(16)
                    .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 15) {
                        sectionTitle("连接信息", detail: "Key 只保存在本机，不会在重新打开时显示")

                        connectionField(title: "API 地址", icon: "link") {
                            TextField(provider.defaultBaseURL, text: $baseURL)
                                .textFieldStyle(.plain)
                                .focused($focusedField, equals: .baseURL)
                        }

                        connectionField(title: "模型名称", icon: "cube") {
                            TextField(provider.defaultModel, text: $modelName)
                                .textFieldStyle(.plain)
                                .focused($focusedField, equals: .model)
                        }

                        connectionField(title: "API Key", icon: "key.horizontal") {
                            HStack(spacing: 8) {
                                Group {
                                    if revealsAPIKey {
                                        TextField(savedKeyExists ? "留空则继续使用已保存的 Key" : "输入 API Key", text: $apiKey)
                                    } else {
                                        SecureField(savedKeyExists ? "留空则继续使用已保存的 Key" : "输入 API Key", text: $apiKey)
                                    }
                                }
                                .textFieldStyle(.plain)
                                .focused($focusedField, equals: .apiKey)
                                Button {
                                    revealsAPIKey.toggle()
                                } label: {
                                    Image(systemName: revealsAPIKey ? "eye.slash" : "eye")
                                        .foregroundStyle(RecallPalette.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(revealsAPIKey ? "隐藏 API Key" : "显示 API Key")
                            }
                        }
                    }
                    .padding(16)
                    .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(RecallPalette.border, lineWidth: 1))

                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: connectionStatusSymbol)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(connectionStatusColor)
                            .frame(width: 38, height: 38)
                            .background(connectionStatusColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(connectionStatusTitle)
                                .font(.subheadline.weight(.semibold))
                            Text(connectionStatusDetail)
                                .font(.caption)
                                .foregroundStyle(RecallPalette.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 16)
                        Button(action: testConnection) {
                            if isTestingConnection {
                                HStack(spacing: 7) {
                                    ProgressView().controlSize(.small)
                                    Text("正在测试")
                                }
                            } else {
                                Label("测试连接", systemImage: "bolt.horizontal.circle")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isTestingConnection || effectiveAPIKey.isEmpty || !hasValidEndpoint)
                    }
                    .padding(16)
                    .background(connectionStatusColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(connectionStatusColor.opacity(0.18), lineWidth: 1))
                }
                .padding(24)
            }

            Divider()
            HStack {
                Label("保存后，下一次提问立即使用新连接", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasValidEndpoint || !maySaveConnection)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 700, height: 600)
        .onAppear {
            DispatchQueue.main.async { focusedField = .baseURL }
        }
        .onChange(of: provider) { _, nextProvider in
            baseURL = nextProvider.defaultBaseURL
            modelName = nextProvider.defaultModel
            connectionStatus = nil
        }
        .onChange(of: apiKey) { _, _ in
            connectionStatus = nil
        }
        .onChange(of: baseURL) { _, _ in
            connectionStatus = nil
        }
        .onChange(of: modelName) { _, _ in
            connectionStatus = nil
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(RecallPalette.secondary)
        }
    }

    private func connectionField<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(RecallPalette.secondary)
            content()
                .padding(.horizontal, 12)
                .frame(height: 40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(RecallPalette.border.opacity(0.55), lineWidth: 1))
        }
    }

    private var normalizedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveAPIKey: String {
        normalizedAPIKey.isEmpty
            ? initialConfiguration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            : normalizedAPIKey
    }

    private var hasValidEndpoint: Bool {
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return url.scheme == "https" || url.scheme == "http"
    }

    private var connectionChanged: Bool {
        provider != initialConfiguration.provider
            || baseURL.trimmingCharacters(in: .whitespacesAndNewlines) != initialConfiguration.baseURLString
            || modelName.trimmingCharacters(in: .whitespacesAndNewlines) != initialConfiguration.model
            || !normalizedAPIKey.isEmpty
    }

    private var maySaveConnection: Bool {
        guard !effectiveAPIKey.isEmpty else { return false }
        if !connectionChanged { return savedKeyExists }
        if case .success = connectionStatus { return true }
        return false
    }

    private var connectionStatusTitle: String {
        if isTestingConnection { return "正在验证连接" }
        switch connectionStatus {
        case .success: return "连接可用"
        case .failure: return "连接验证失败"
        case .none: return connectionChanged ? "需要验证连接" : "当前连接已保存"
        }
    }

    private var connectionStatusDetail: String {
        if isTestingConnection { return "正在向模型服务发送最小测试请求…" }
        switch connectionStatus {
        case .success(let message): return message
        case .failure(let message): return message
        case .none:
            return connectionChanged
                ? "修改协议、地址、模型或 Key 后，请先测试再保存。"
                : "未修改连接信息；测试不会发送本地记忆。"
        }
    }

    private var connectionStatusSymbol: String {
        if isTestingConnection { return "arrow.triangle.2.circlepath" }
        switch connectionStatus {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        case .none: return connectionChanged ? "bolt.horizontal.circle" : "checkmark.shield.fill"
        }
    }

    private var connectionStatusColor: Color {
        if isTestingConnection { return .accentColor }
        switch connectionStatus {
        case .success: return RecallPalette.accent
        case .failure: return RecallPalette.danger
        case .none: return connectionChanged ? RecallPalette.warning : RecallPalette.accent
        }
    }

    private func makeConfiguration() -> LLMConfiguration {
        LLMConfiguration(
            provider: provider,
            baseURLString: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: effectiveAPIKey,
            anthropicVersion: initialConfiguration.anthropicVersion,
            maxOutputTokens: initialConfiguration.maxOutputTokens
        )
    }

    private func testConnection() {
        guard !effectiveAPIKey.isEmpty, hasValidEndpoint else { return }
        isTestingConnection = true
        connectionStatus = nil
        let configuration = makeConfiguration()
        let key = effectiveAPIKey
        Task {
            do {
                let answer = try await CompatibleLLM(configuration: configuration, apiKey: key).answer(
                    to: LLMRequest(question: "仅回复连接成功", context: [])
                )
                await MainActor.run {
                    isTestingConnection = false
                    connectionStatus = .success("连接成功：\(answer.content.prefix(80))")
                }
            } catch {
                await MainActor.run {
                    isTestingConnection = false
                    connectionStatus = .failure("认证或连接失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func save() {
        let configuration = makeConfiguration()
        onSave(configuration, normalizedAPIKey)
        dismiss()
    }
}

extension RecallRootView {
    @MainActor static func previewPage(_ name: String) -> AnyView {
        switch name {
        case "navigation": AnyView(RecallRootView())
        case "daily": AnyView(DailySummariesView())
        case "topics", "period", "knowledge", "knowledge-empty": AnyView(MatterWorkspaceView(continueChat: { _ in }))
        case "rules": AnyView(EventRulesView())
        case "reminders": AnyView(RemindersView())
        case "timeline": AnyView(TimelineView())
        case "settings": AnyView(PrivacyAndModelView())
        default: AnyView(ChatView())
        }
    }
}
