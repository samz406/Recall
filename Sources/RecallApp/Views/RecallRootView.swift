import RecallKit
import Foundation
import SwiftUI
import AppKit

struct RecallRootView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var section: SidebarSection? = .timeline
    @State private var showingRecordSheet = false
    @State private var noticeDismissal: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("记忆") {
                    Label("每日总结", systemImage: "calendar.badge.clock")
                        .badge(highPrioritySummaryTodoCount)
                        .tag(SidebarSection.dailySummaries)
                    Label("问一问", systemImage: "bubble.left.and.bubble.right")
                        .tag(SidebarSection.chat)
                    Label("时间线", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarSection.timeline)
                    Label("提醒", systemImage: "bell.badge")
                        .badge(proposedReminderCount)
                        .tag(SidebarSection.reminders)
                }
                Section("控制") {
                    Label("记录事件", systemImage: "checklist")
                        .tag(SidebarSection.rules)
                    Label("隐私与模型", systemImage: "lock.shield")
                        .tag(SidebarSection.privacy)
                }
            }
            .navigationTitle("Recall")

        } detail: {
            Group {
                switch section ?? .timeline {
                case .timeline: TimelineView()
                case .chat: ChatView()
                case .dailySummaries: DailySummariesView()
                case .reminders: RemindersView()
                case .rules: EventRulesView()
                case .privacy: PrivacyAndModelView()
                }
            }
            .toolbar {
                if model.isRecording || model.isThinking {
                    ProgressView()
                        .controlSize(.small)
                }
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
        .animation(.easeInOut(duration: 0.22), value: model.noticeMessage)
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
    }

    private var highPrioritySummaryTodoCount: Int {
        model.state.dailySummaries.first?.todos.filter { $0.priority == .high }.count ?? 0
    }

    private var proposedReminderCount: Int {
        model.state.reminders.filter { $0.status == .proposed }.count
    }
}

private enum SidebarSection: Hashable {
    case timeline, chat, dailySummaries, reminders, rules, privacy
}

private struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
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
                .foregroundStyle(.secondary)
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

private struct TimelineView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var searchText = ""
    @State private var expandedDayIDs: Set<Date> = []
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)

    private var availableDayOptions: [TimelineDayOption] {
        let calendar = Calendar.current
        let counts = model.state.captures.reduce(into: [Date: Int]()) { result, capture in
            result[calendar.startOfDay(for: capture.createdAt), default: 0] += 1
        }
        return counts.keys
            .sorted(by: >)
            .prefix(14)
            .map { TimelineDayOption(day: $0, count: counts[$0] ?? 0) }
    }

    private var selectedDayCaptures: [CaptureRecord] {
        TimelineGrouping.captures(on: selectedDay, from: model.state.captures)
    }

    private var captures: [CaptureRecord] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return selectedDayCaptures }
        return MemorySearchEngine().search(MemorySearchQuery(text: searchText), in: selectedDayCaptures).map(\.capture)
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
            if model.state.captures.isEmpty {
                timelineEmptyState
            } else {
                TextField("搜索所选日期的本地记忆", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 14)

                dayNavigator
                Divider()

                if captures.isEmpty {
                    selectedDayEmptyState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(dayGroups) { group in
                                TimelineDaySection(
                                    group: group,
                                    title: dayTitle(for: group.day),
                                    isSearchResult: isSearching,
                                    isExpanded: expandedDayIDs.contains(group.id),
                                    onToggle: { toggle(group.id) },
                                    onDelete: model.deleteCapture
                                )
                                .id(group.id)
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { initializeExpandedDays() }
        .onChange(of: searchText) { _, _ in initializeExpandedDays() }
        .onChange(of: selectedDay) { _, _ in initializeExpandedDays() }
        .onChange(of: dayGroups.map(\.id)) { _, _ in initializeExpandedDays() }
    }

    private var timelineHeader: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text("记忆时间线")
                    .font(.title2.weight(.semibold))
                Text("按天回看本地记录；每条内容都可以追溯和删除。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            Label("本地优先", systemImage: "lock.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary, in: Capsule())
            Button {
                model.requestScreenRecordingAccess()
            } label: {
                Label("检查屏幕权限", systemImage: "checkmark.shield")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }

    private var timelineEmptyState: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 58, height: 58)
                    .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 6) {
                    Text("从第一条本地记录开始")
                        .font(.title3.weight(.semibold))
                    Text("完成屏幕录制授权后，启用的记录事件产生的内容会显示在这里。所有截图、OCR 和索引默认保存在这台 Mac 上。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
                    title: "设置记录事件",
                    detail: "在左侧“记录事件”中选择需要的触发方式。"
                )
                Divider().frame(height: 48)
                TimelineEmptyStateStep(
                    number: "3",
                    icon: "calendar.badge.clock",
                    title: "回看与总结",
                    detail: "记录会按天整理，并可生成每日总结。"
                )
            }

            HStack(spacing: 12) {
                Button {
                    model.requestScreenRecordingAccess()
                } label: {
                    Label("检查屏幕权限", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                Text("你随时可以在“隐私与模型”中暂停采集或删除本地数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(maxWidth: 820, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.quaternary, lineWidth: 1))
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var selectedDayEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: isSearching ? "magnifyingglass" : "calendar.badge.clock")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text(isSearching ? "当天没有匹配的记录" : "当天没有记录")
                .font(.headline)
            Text(isSearching
                 ? "搜索只作用于当前选择的日期，可更换关键词或切换日期。"
                 : "\(dayTitle(for: selectedDay)) 暂无本地记录，可通过上方日期栏查看其他日期。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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

                DatePicker(
                    "选择日期",
                    selection: Binding(
                        get: { selectedDay },
                        set: { selectDay($0) }
                    ),
                    in: ...Date.now,
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)

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
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.clear : Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
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
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    let onDelete: (CaptureRecord) -> Void

    var body: some View {
        Section {
            if isExpanded {
                ForEach(group.captures) { capture in
                    CaptureRow(capture: capture, onDelete: onDelete)
                        .contextMenu {
                            Button("删除记录", role: .destructive) { onDelete(capture) }
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
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding(.bottom, 8)
    }
}

private struct CaptureRow: View {
    let capture: CaptureRecord
    let onDelete: (CaptureRecord) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: capture.imageRelativePath == nil ? "doc.text" : "rectangle.on.rectangle")
                .frame(width: 34, height: 34)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(capture.eventTemplate.title)
                        .font(.headline)
                    if capture.isRedacted {
                        Label("已脱敏", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(capture.summary ?? "未识别出文本")
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(capture.createdAt.formatted(date: .omitted, time: .shortened))
                    if let source = capture.sourceAppName { Text(source) }
                    ForEach(capture.tags.prefix(3), id: \.self) { tag in
                        Text(tag).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(role: .destructive) { onDelete(capture) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 8)
    }
}

private struct ChatView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var question = ""
    @State private var scrollRequest = 0

    private var isCloudModel: Bool {
        model.state.llmConfiguration.provider != .localOnly && model.state.privacy.cloudUseEnabled
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                chatHeader
                Divider().opacity(0.55)
                if model.state.messages.isEmpty {
                    ChatWelcomeView(onSelect: { question = $0 })
                } else {
                    messageTimeline
                }
                ChatComposer(
                    question: $question,
                    isSending: model.isThinking,
                    onSend: send
                )
            }
        }
    }

    private var chatHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text("问一问")
                    .font(.system(size: 18, weight: .semibold))
                Text("基于你的本地记忆与可追溯来源")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: isCloudModel ? "cloud.fill" : "lock.fill")
                Text(isCloudModel ? model.state.llmConfiguration.provider.title : "本地模式")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(isCloudModel ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
            if model.state.conversationSummary != nil {
                Label("长对话已压缩", systemImage: "text.compress")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 18)
    }

    private var messageTimeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(model.state.messages) { message in
                        RecallMessageCard(message: message)
                        .id(message.id)
                    }
                    if model.isThinking {
                        ThinkingCard()
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(ChatScrollAnchor.bottom)
                }
                .frame(maxWidth: 860)
                .padding(.horizontal, 32)
                .padding(.vertical, 30)
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    scrollToLatest(using: proxy)
                } label: {
                    Label("最新", systemImage: "arrow.down.to.line.compact")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .padding(18)
                .help("滚动到最新消息")
            }
            .onAppear {
                scrollToLatest(using: proxy, animated: false)
            }
            .onChange(of: model.state.messages.last?.id) { _, _ in
                scrollToLatest(using: proxy)
            }
            .onChange(of: model.isThinking) { _, _ in
                scrollToLatest(using: proxy)
            }
            .onChange(of: scrollRequest) { _, _ in
                scrollToLatest(using: proxy, animated: false)
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
                .foregroundStyle(Color.accentColor)
                .frame(width: 76, height: 76)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 24))
            VStack(spacing: 8) {
                Text("今天想回忆什么？")
                    .font(.system(size: 30, weight: .semibold))
                Text("Recall 会先检索相关记忆，再给出带来源的回答。")
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(suggestions, id: \.0) { suggestion in
                    Button {
                        onSelect(suggestion.0)
                    } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            Image(systemName: suggestion.1)
                                .foregroundStyle(Color.accentColor)
                            Text(suggestion.0)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(suggestion.2)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                        .padding(16)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 720)
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

private struct RecallMessageCard: View {
    let message: ConversationMessage

    var body: some View {
        Group {
            if message.role == .user {
                HStack(alignment: .top) {
                    Spacer(minLength: 24)
                    messageBody
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor, in: Circle())
                    messageBody
                    Spacer(minLength: 24)
                }
            }
        }
    }

    private var messageBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(message.role == .user ? "你" : "Recall")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if message.role == .assistant {
                MarkdownParagraphText(markdown: ChatResponseFormatter().format(message.content))
            } else {
                Text(message.content)
                    .font(.system(size: 17))
                    .textSelection(.enabled)
                    .lineSpacing(5)
            }
            if !message.citations.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                    Text("引用了 \(message.citations.count) 条记忆来源")
                }
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: message.role == .user ? 590 : .infinity, alignment: .leading)
        .background(message.role == .user ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(message.role == .user ? Color.clear : Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
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
                    .font(.system(size: 17))
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
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Recall 正在检索记忆并组织回答…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ChatComposer: View {
    @Binding var question: String
    let isSending: Bool
    let onSend: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("向 Recall 提问…", text: $question, axis: .vertical)
                .focused($isFocused)
                .textFieldStyle(.plain)
                .lineLimit(1...7)
                .font(.system(size: 18))
                .padding(.leading, 4)
                .padding(.vertical, 10)
                .submitLabel(.send)
                .onKeyPress(.return) {
                    submit()
                    return .handled
                }
            Button(action: submit) {
                Image(systemName: isSending ? "ellipsis" : "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(sendButtonColor, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.leading, 16)
        .padding(.trailing, 9)
        .padding(.vertical, 10)
        .frame(minHeight: 89)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(isFocused ? Color.accentColor.opacity(0.65) : Color(nsColor: .separatorColor).opacity(0.55), lineWidth: isFocused ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(isFocused ? 0.09 : 0.055), radius: isFocused ? 20 : 14, y: 6)
        .animation(.easeOut(duration: 0.16), value: isFocused)
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }

    private var canSend: Bool {
        !isSending && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendButtonColor: Color {
        canSend ? Color.accentColor : Color.secondary.opacity(0.45)
    }

    private func submit() {
        guard canSend else { return }
        onSend()
    }
}

private struct DailySummariesView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var expandedSummaryID: UUID?
    @State private var visibleSummaryCount = 12

    private let pageSize = 12

    private var summaries: [DailySummary] {
        model.state.dailySummaries.sorted { $0.day > $1.day }
    }

    private var visibleSummaries: [DailySummary] {
        Array(summaries.prefix(visibleSummaryCount))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if summaries.isEmpty {
                    emptyState
                } else {
                    history
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("每日总结")
        .onAppear {
            if expandedSummaryID == nil {
                expandedSummaryID = summaries.first?.id
            }
        }
        .onChange(of: summaries.first?.id) { _, latestID in
            expandedSummaryID = latestID
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("每日总结历史")
                        .font(.title3.weight(.semibold))
                    Text("默认展开最新一条；其余以紧凑预览显示，点击即可查看全文。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("共 \(summaries.count) 条")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            ForEach(visibleSummaries) { summary in
                DailySummaryCard(
                    summary: summary,
                    isExpanded: expandedSummaryID == summary.id,
                    onToggle: { toggle(summary) },
                    onDelete: { model.deleteDailySummary(summary) },
                    onReviewInsight: { insight, rating in model.reviewInsight(insight, rating: rating) },
                    onReviewMemory: { memory, status in model.reviewUserMemory(memory, status: status) },
                    onUpdateRoutine: { routine, status in model.updateLearnedRoutine(routine, status: status) }
                )
            }
            if visibleSummaries.count < summaries.count {
                Button {
                    visibleSummaryCount += pageSize
                } label: {
                    Label("显示更多（还剩 \(summaries.count - visibleSummaries.count) 条）", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("每日总结", systemImage: "calendar.badge.clock")
                    .font(.system(size: 24, weight: .semibold))
                Text("在指定时间汇总前一天的显式记录；仅在你已允许云端文本使用且配置 API Key 时发送最小化、已脱敏的文本片段。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.state.dailySummarySettings.isEnabled {
                    Label("已开启：每天 \(dailySummaryTimeText) 自动汇总前一天", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    Label("自动总结当前关闭，可在“隐私与模型”中设置时间并开启", systemImage: "pause.circle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 20)
            Button {
                model.generatePreviousDaySummaryNow()
            } label: {
                Label("立即总结昨天", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isThinking)
        }
        .padding(22)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.quaternary, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
            Text("还没有每日总结")
                .font(.title2.weight(.semibold))
            Text("先记录一些工作节点；你可以点击“立即总结昨天”，也可以在“隐私与模型”中设置每天自动执行的时间。")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.quaternary, lineWidth: 1))
    }

    private var dailySummaryTimeText: String {
        let settings = model.state.dailySummarySettings
        return String(format: "%02d:%02d", settings.hour, settings.minute)
    }

    private func toggle(_ summary: DailySummary) {
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedSummaryID = expandedSummaryID == summary.id ? nil : summary.id
        }
    }
}

private struct DailySummaryCard: View {
    let summary: DailySummary
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onReviewInsight: (PersonalInsight, InsightFeedbackRating) -> Void
    let onReviewMemory: (UserMemory, MemoryReviewStatus) -> Void
    let onUpdateRoutine: (LearnedRoutine, LearnedRoutineStatus) -> Void

    private var preview: String {
        if let briefing = summary.briefing { return briefing.headline }
        let text = summary.content
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
                Button(action: onToggle) {
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle")
                            .foregroundStyle(Color.accentColor)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.day.formatted(.dateTime.year().month().day().weekday()))
                                .font(.headline)
                            HStack(spacing: 8) {
                                Label(summary.generationKind == .cloud ? "模型生成" : "本地摘要", systemImage: summary.generationKind == .cloud ? "cpu" : "text.document")
                                if !summary.todos.isEmpty {
                                    Label("\(summary.todos.count) 项待办", systemImage: "checklist")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button("删除", role: .destructive, action: onDelete)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            if isExpanded {
                Divider()
                if let briefing = summary.briefing {
                    DailyBriefingView(
                        briefing: briefing,
                        feedback: summaryFeedback,
                        memoryStates: memoryStates,
                        routineStates: routineStates,
                        onReviewInsight: onReviewInsight,
                        onReviewMemory: onReviewMemory,
                        onUpdateRoutine: onUpdateRoutine
                    )
                } else {
                    MarkdownDocumentView(markdown: summary.content)
                        .textSelection(.enabled)
                }
            } else {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 34)
            }
        }
        .padding(isExpanded ? 19 : 15)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(isExpanded ? Color.accentColor.opacity(0.28) : Color.gray.opacity(0.22), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @EnvironmentObject private var model: RecallAppModel

    private var summaryFeedback: [UUID: InsightFeedbackRating] {
        Dictionary(uniqueKeysWithValues: model.state.insightFeedback.map { ($0.insightID, $0.rating) })
    }

    private var memoryStates: [UUID: MemoryReviewStatus] {
        Dictionary(uniqueKeysWithValues: model.state.userMemories.map { ($0.id, $0.status) })
    }

    private var routineStates: [UUID: LearnedRoutineStatus] {
        Dictionary(uniqueKeysWithValues: model.state.learnedRoutines.map { ($0.id, $0.status) })
    }
}

private struct DailyBriefingView: View {
    let briefing: DailyBriefing
    let feedback: [UUID: InsightFeedbackRating]
    let memoryStates: [UUID: MemoryReviewStatus]
    let routineStates: [UUID: LearnedRoutineStatus]
    let onReviewInsight: (PersonalInsight, InsightFeedbackRating) -> Void
    let onReviewMemory: (UserMemory, MemoryReviewStatus) -> Void
    let onUpdateRoutine: (LearnedRoutine, LearnedRoutineStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "scope")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("今天的主线").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(briefing.headline).font(.headline)
                }
            }
            briefingSection("真正完成的进展", icon: "checkmark.seal.fill", color: .green, items: briefing.progress, empty: "暂未识别出形成结果的关键进展。")
            briefingSection("尚未闭环", icon: "circle.dashed", color: .orange, items: briefing.openLoops, empty: "未发现有明确证据的未闭环事项。")

            if !briefing.insights.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Recall 的发现", icon: "sparkles", color: .purple)
                    ForEach(briefing.insights) { insight in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(insight.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("置信度 \(Int(insight.confidence * 100))%")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(insight.detail).font(.subheadline).foregroundStyle(.secondary)
                            if let recommendation = insight.recommendation {
                                Label(recommendation, systemImage: "arrow.right.circle.fill")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.accentColor)
                            }
                            insightFeedbackControls(insight)
                        }
                        .padding(12)
                        .background(Color.purple.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }

            briefingSection("下一步", icon: "arrow.up.right.circle.fill", color: .blue, items: briefing.nextActions, empty: "暂无需要主动打断你的建议。")
            memoryReview
            routineReview
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func briefingSection(_ title: String, icon: String, color: Color, items: [BriefingItem], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title, icon: icon, color: color)
            if items.isEmpty {
                Text(empty).font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 2)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func insightFeedbackControls(_ insight: PersonalInsight) -> some View {
        if let rating = feedback[insight.id] {
            Label(feedbackTitle(rating), systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 14) {
                Text("这个判断准确吗？").font(.caption).foregroundStyle(.secondary)
                Button("准确") { onReviewInsight(insight, .accurate) }
                Button("部分准确") { onReviewInsight(insight, .partiallyAccurate) }
                Button("不准确") { onReviewInsight(insight, .inaccurate) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    @ViewBuilder
    private var memoryReview: some View {
        if !briefing.memoryCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("我对你的新认识", icon: "person.text.rectangle", color: .indigo)
                Text("只有你确认后，它才会进入长期用户档案。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(briefing.memoryCandidates) { memory in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(memory.kind.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(memory.content).font(.subheadline)
                        }
                        Spacer()
                        let status = memoryStates[memory.id] ?? memory.status
                        if status == .proposed {
                            Button("准确") { onReviewMemory(memory, .confirmed) }
                            Button("不准确") { onReviewMemory(memory, .rejected) }
                        } else {
                            Text(status == .confirmed ? "已确认" : "已否定").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(12)
            .background(Color.indigo.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var routineReview: some View {
        if !briefing.routineCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("可学习的个人规则", icon: "wand.and.stars", color: .teal)
                ForEach(briefing.routineCandidates) { routine in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(routine.title).font(.subheadline.weight(.semibold))
                            Text("\(routine.trigger)，\(routine.suggestedAction)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let status = routineStates[routine.id] ?? routine.status
                        if status == .proposed {
                            Button("启用") { onUpdateRoutine(routine, .enabled) }
                            Button("忽略") { onUpdateRoutine(routine, .dismissed) }
                        } else {
                            Text(status == .enabled ? "已启用" : "已忽略").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(12)
            .background(Color.teal.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
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
}

private struct MarkdownDocumentView: View {
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
                        Text("•").font(.body.weight(.bold))
                        inlineText(text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 4)
                case let .orderedList(marker, text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).font(.body.weight(.semibold)).foregroundStyle(.secondary)
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
            return Text(text)
        }
        return Text(attributed)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.bold)
        default: .headline
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
    @State private var isConfirmingDismissAll = false
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
            .filter { $0.status == .scheduled }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
    }

    private var completed: [ReminderCandidate] {
        model.state.reminders
            .filter { $0.status == .completed }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var isDiscovering: Bool {
        if case .searching = model.reminderDiscoveryStatus { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                reminderHeader
                workflow
                reminderDiscoveryFeedback
                if proposed.isEmpty && scheduled.isEmpty && completed.isEmpty {
                    ReminderEmptyState(isDiscovering: isDiscovering, onDiscover: model.proposeReminders)
                } else {
                    reminderLists
                }
            }
            .frame(maxWidth: 1_100)
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $reminderBeingScheduled) { reminder in
            ReminderScheduleSheet(reminder: reminder) { dueAt in
                model.approveReminder(reminder, dueAt: dueAt)
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
        .task(id: proposed.count) {
            if !proposed.isEmpty, case .idle = model.reminderDiscoveryStatus {
                model.proposeReminders()
            }
        }
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

    private var reminderHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "bell.badge.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 5) {
                Text("提醒")
                    .font(.system(size: 26, weight: .semibold))
                Text("把容易遗忘的未闭环行动变成可确认、可追溯、可完成的提醒。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            HStack(spacing: 10) {
                Button(action: model.verifyReminderDelivery) {
                    Label("核验状态", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Button {
                    model.proposeReminders()
                } label: {
                    if isDiscovering {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("正在检索")
                        }
                    } else {
                        Label("从记忆中发现", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDiscovering)
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary, lineWidth: 1))
    }

    private var workflow: some View {
        HStack(spacing: 14) {
            Label("候选不等于任务", systemImage: "scope")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.trailing, 10)
            Divider().frame(height: 26)
            ReminderWorkflowStep(number: "1", title: "识别行动", detail: "过滤疑问、完成态与噪声")
            ReminderWorkflowStep(number: "2", title: "查看来源", detail: "核对对应记忆")
            ReminderWorkflowStep(number: "3", title: "由你安排", detail: "确认后才通知")
            ReminderWorkflowStep(number: "4", title: "完成闭环", detail: "完成、改期或取消")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor.opacity(0.16), lineWidth: 1))
    }

    @ViewBuilder
    private var reminderDiscoveryFeedback: some View {
        switch model.reminderDiscoveryStatus {
        case .idle:
            EmptyView()
        case let .searching(scannedRecordCount):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在分析 \(scannedRecordCount) 条可用于提醒的近期记录…")
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.accentColor.opacity(0.075), in: RoundedRectangle(cornerRadius: 14))
        case let .completed(scannedRecordCount, discoveredCount, _):
            HStack(spacing: 10) {
                Image(systemName: discoveredCount > 0 ? "checkmark.circle.fill" : "magnifyingglass")
                    .foregroundStyle(discoveredCount > 0 ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(discoveredCount > 0 ? "已从 \(scannedRecordCount) 条本地记录中发现 \(discoveredCount) 项候选" : "已检索 \(scannedRecordCount) 条本地记录，暂未发现新的候选")
                        .font(.subheadline.weight(.medium))
                    Text(discoveredCount > 0 ? "已过滤疑问、完成态、代码噪声与重复内容，请核对来源后再安排。" : "以后新增可执行事项后，可以再次运行本地检索。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background((discoveredCount > 0 ? Color.green : Color.secondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private var reminderLists: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !proposed.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("待你确认")
                            .font(.title3.weight(.semibold))
                        Text("\(proposed.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
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
            if !scheduled.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("已安排")
                            .font(.title3.weight(.semibold))
                        Text("\(scheduled.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                        Text("已由 macOS 核验")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("“已推送”仅表示通知中心已接收，不代表已阅读")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(paged(scheduled, page: scheduledPage)) { reminder in
                        reminderCard(reminder, deliveryState: model.reminderDeliveryStates[reminder.id])
                    }
                    ReminderPagination(page: $scheduledPage, itemCount: scheduled.count, pageSize: pageSize)
                }
            }
            if !completed.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("已完成")
                            .font(.title3.weight(.semibold))
                        Text("\(completed.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
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

    private func reminderCard(_ reminder: ReminderCandidate, deliveryState: ReminderDeliveryState?) -> some View {
        ReminderCandidateCard(
            reminder: reminder,
            deliveryState: deliveryState,
            schedule: { reminderBeingScheduled = reminder },
            complete: { model.completeReminder(reminder) },
            dismiss: { model.dismissReminder(reminder) },
            viewSources: { reminderShowingSources = reminder }
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
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(.white)
                .frame(width: 23, height: 23)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReminderEmptyState: View {
    let isDiscovering: Bool
    let onDiscover: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "bell.and.waves.left.and.right")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 58, height: 58)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                Text("还没有待确认的提醒")
                    .font(.title3.weight(.semibold))
                Text("检查已有记忆中的待办、承诺和截止事项。Recall 只会提出候选，不会自行打扰你。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onDiscover) {
                    if isDiscovering {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("正在检索本地记忆")
                        }
                    } else {
                        Label("从记忆中发现提醒", systemImage: "sparkle.magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDiscovering)
            }
            .frame(maxWidth: 340, alignment: .leading)

            Divider().frame(height: 210)

            VStack(alignment: .leading, spacing: 18) {
                Text("发现后，你始终拥有决定权")
                    .font(.subheadline.weight(.semibold))
                ReminderFeature(icon: "checkmark.circle", title: "识别待办", detail: "从已有记忆中找出值得跟进的事项")
                ReminderFeature(icon: "person.crop.circle.badge.clock", title: "关联来源", detail: "可回看每项候选来自哪条本地记录")
                ReminderFeature(icon: "hand.tap", title: "由你决定", detail: "只有确认并设置时间后才安排通知")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(30)
        .frame(maxWidth: 880, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.quaternary, lineWidth: 1))
    }
}

private struct ReminderFeature: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
            Text(title).font(.caption.weight(.semibold))
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReminderScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let reminder: ReminderCandidate
    let onConfirm: (Date) -> Void
    @State private var selectedDate: Date

    init(reminder: ReminderCandidate, onConfirm: @escaping (Date) -> Void) {
        self.reminder = reminder
        self.onConfirm = onConfirm
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now.addingTimeInterval(24 * 60 * 60)
        let fallback = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        let earliest = Date.now.addingTimeInterval(60)
        _selectedDate = State(initialValue: max(reminder.dueAt ?? fallback, earliest))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(reminder.status == .scheduled ? "修改提醒时间" : "设置提醒时间")
                    .font(.title2.weight(.semibold))
                Text(reminder.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if reminder.status == .scheduled, let currentDate = reminder.dueAt {
                    Text("当前安排：\(currentDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                } else if let suggestedDate = reminder.dueAt {
                    Text("已根据记录中的时间线索预填建议时间，你可以直接修改。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("建议：\(suggestedDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("记录中没有明确时间；已预填明天上午 9:00，请按需要调整。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            DatePicker(
                "提醒时间",
                selection: $selectedDate,
                in: Date.now...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.field)

            HStack {
                Text("创建后仍可在“已安排”中取消提醒。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button(reminder.status == .scheduled ? "保存修改" : "确认并创建") {
                    onConfirm(selectedDate)
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
                        .foregroundStyle(.secondary)
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
                                .foregroundStyle(.secondary)
                        }
                        Text(capture.summary ?? capture.ocrText)
                            .font(.subheadline)
                            .textSelection(.enabled)
                            .lineLimit(8)
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.inset)
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
    let dismiss: () -> Void
    let viewSources: () -> Void

    private var statusColor: Color {
        switch reminder.status {
        case .proposed: .accentColor
        case .scheduled: .green
        case .completed: .secondary
        case .dismissed: .secondary
        }
    }

    private var statusIcon: String {
        switch reminder.status {
        case .proposed: "bell.badge"
        case .scheduled: "bell.fill"
        case .completed: "checkmark.circle.fill"
        case .dismissed: "bell.slash"
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
                Text(reminder.detail).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button(action: viewSources) {
                        Label("查看 \(reminder.sourceCaptureIDs.count) 条来源", systemImage: "link")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    if let dueAt = reminder.dueAt {
                        Label(
                            reminder.status == .proposed ? "建议：\(dueAt.formatted(date: .abbreviated, time: .shortened))" : dueAt.formatted(date: .abbreviated, time: .shortened),
                            systemImage: "calendar"
                        )
                    } else if reminder.status == .proposed {
                        Label("创建前选择时间", systemImage: "calendar.badge.clock")
                    }
                    if reminder.status == .proposed {
                        Text("可信度 \(Int(reminder.confidence * 100))%")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                if reminder.status == .scheduled {
                    ReminderDeliveryBadge(state: deliveryState)
                } else if reminder.status == .completed {
                    Label("已由你标记完成", systemImage: "checkmark.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if reminder.status == .scheduled {
                VStack(alignment: .trailing, spacing: 8) {
                    Text(deliveryState == .delivered ? "已推送" : "已安排")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(deliveryState == .notFound ? .orange : .green)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background((deliveryState == .notFound ? Color.orange : Color.green).opacity(0.10), in: Capsule())
                    Button("修改时间", action: schedule)
                        .buttonStyle(.bordered)
                        .font(.caption)
                    Button("标记完成", action: complete)
                        .buttonStyle(.borderedProminent)
                        .font(.caption)
                    Button("取消提醒", role: .destructive, action: dismiss)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            } else if reminder.status == .proposed {
                VStack(alignment: .trailing, spacing: 8) {
                    Button("选择时间并创建", action: schedule)
                        .buttonStyle(.borderedProminent)
                    Button("忽略", role: .destructive, action: dismiss)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            } else if reminder.status == .completed {
                VStack(alignment: .trailing, spacing: 8) {
                    Text("已完成")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Button("从列表移除", action: dismiss)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary, lineWidth: 1))
    }
}

private struct ReminderDeliveryBadge: View {
    let state: ReminderDeliveryState?

    private var presentation: (text: String, symbol: String, color: Color) {
        switch state {
        case .pending:
            return ("已写入系统通知队列，等待投递", "clock.badge.checkmark", .blue)
        case .delivered:
            return ("已推送到 macOS 通知中心", "checkmark.bubble", .green)
        case .notFound:
            return ("未在 macOS 通知队列中找到", "exclamationmark.triangle", .orange)
        case .none:
            return ("正在核验 macOS 通知状态", "arrow.triangle.2.circlepath", .secondary)
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

    var body: some View {
        List {
            Section {
                Text("勾选你希望 Recall 记录的事件。每一类都可以独立配置采集范围、保留周期和是否用于提醒。裸 Enter 监听不会被默认启用。")
                    .foregroundStyle(.secondary)
            }
            Section("事件模板") {
                ForEach(model.state.rules) { rule in
                    EventRuleRow(rule: rule)
                }
            }
        }
        .navigationTitle("记录事件")
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
                        Text(rule.template.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button(expanded ? "收起" : "配置") { expanded.toggle() }
                    .buttonStyle(.borderless)
            }
            if rule.template == .enterKeyTrigger {
                HStack(spacing: 8) {
                    Label(model.enterKeyMonitorStatus.title, systemImage: model.enterKeyMonitorStatus.symbolName)
                        .font(.caption)
                        .foregroundStyle(model.enterKeyMonitorStatus == .monitoring ? Color.green : Color.orange)
                    Spacer()
                    Button("检查跨应用权限") {
                        model.checkEnterKeyMonitor()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                Text("跨应用触发需同时获得“输入监控”和“辅助功能”授权；实际截图仍需屏幕录制权限。监听不拦截按键，且仅在 Recall 不在前台时触发。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                Stepper("\(retainImages) 天", value: $retainImages, in: 0...365)
            }
            GridRow {
                Text("文本保留")
                Stepper("\(retainText) 天", value: $retainText, in: 1...3650)
            }
            GridRow {
                Text("应用白名单")
                TextField("Bundle ID，以逗号分隔", text: $allowList)
            }
        }
        Toggle("允许会话检索此类记录", isOn: $includeChat)
        Toggle("允许从此类记录提出提醒候选", isOn: $includeReminders)
        Button("保存规则") {
            var updated = rule
            updated.scope = scope
            updated.retainImageDays = retainImages
            updated.retainTextDays = retainText
            updated.participatesInChat = includeChat
            updated.participatesInReminders = includeReminders
            updated.appAllowList = allowList.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            model.updateRule(updated)
        }
        .buttonStyle(.bordered)
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
                        .foregroundStyle(.secondary)
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
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.message)
                            .font(.subheadline)
                        if !entry.metadata.isEmpty {
                            Text(entry.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("最多保留 200 条；仅保存在此 Mac。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空日志", role: .destructive) { model.clearDiagnosticLog() }
            }
            .padding(16)
        }
        .frame(width: 720, height: 560)
    }

    private func color(for level: RecallDiagnosticLevel) -> Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                settingsHeader

                LazyVGrid(
                    columns: [GridItem(.flexible(minimum: 360), spacing: 18), GridItem(.flexible(minimum: 360), spacing: 18)],
                    alignment: .leading,
                    spacing: 18
                ) {
                    settingsCard(title: "屏幕与数据", icon: "lock.shield") {
                        Toggle("暂停全部屏幕采集", isOn: privacyBinding(\.screenCapturePaused))
                        Toggle("保留原始截图", isOn: privacyBinding(\.retainScreenshots))
                        VStack(alignment: .leading, spacing: 7) {
                            Text("排除的应用")
                                .font(.subheadline.weight(.medium))
                            TextField("输入 Bundle ID，以逗号分隔", text: $excludedApps)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Label(model.state.privacy.screenCapturePaused ? "采集已暂停" : "采集由你控制", systemImage: model.state.privacy.screenCapturePaused ? "pause.circle" : "hand.raised.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("检查屏幕权限") { model.requestScreenRecordingAccess() }
                                .buttonStyle(.bordered)
                        }
                    }

                    settingsCard(title: "模型连接", icon: "cpu") {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: activeConfiguration.provider == .anthropicCompatible ? "a.circle.fill" : "o.circle.fill")
                                .font(.system(size: 25))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 42, height: 42)
                                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(activeConfiguration.provider.title)
                                    .font(.headline)
                                Text(activeConfiguration.model)
                                    .font(.subheadline.weight(.medium))
                                Text(activeConfiguration.baseURLString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Image(systemName: savedKeyExists ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(savedKeyExists ? .green : .orange)
                        }
                        Toggle("允许发送已检索的脱敏文本", isOn: privacyBinding(\.cloudUseEnabled))
                        HStack {
                            Text(savedKeyExists ? "连接凭据已保存在本机" : "配置 Key 后才会使用云端模型")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("编辑连接") { isEditingModelConnection = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }

                    settingsCard(title: "每日总结", icon: "calendar.badge.clock", tint: .indigo) {
                        Toggle("每天自动汇总前一天", isOn: dailySummaryEnabledBinding)
                        Toggle("总结完成后发送系统通知", isOn: dailySummaryNotificationBinding)
                            .disabled(!model.state.dailySummarySettings.isEnabled)
                        HStack {
                            Label(model.state.dailySummarySettings.isEnabled ? "已启用" : "当前关闭", systemImage: model.state.dailySummarySettings.isEnabled ? "checkmark.circle.fill" : "pause.circle")
                                .font(.caption)
                                .foregroundStyle(model.state.dailySummarySettings.isEnabled ? .green : .secondary)
                            Spacer()
                            DatePicker(
                                "执行时间",
                                selection: dailySummaryTimeBinding,
                                displayedComponents: .hourAndMinute
                            )
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .disabled(!model.state.dailySummarySettings.isEnabled)
                        }
                        Text("仅汇总前一天已保存的显式记录；通知默认关闭，只有你主动开启后才会请求系统权限。云端模型未启用时会保存本地智能简报。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsCard(title: "本地诊断", icon: "stethoscope", tint: .orange) {
                        Text("仅保留权限状态、事件模板、操作结果和错误代码；不包含 API Key、聊天正文、OCR 或截图。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Label("当前 \(model.diagnosticEntries.count) 条", systemImage: "list.bullet.rectangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("查看日志") { isShowingDiagnostics = true }
                                .buttonStyle(.bordered)
                        }
                    }
                }

                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .frame(width: 34, height: 34)
                        .background(Color.red.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("危险操作")
                            .font(.subheadline.weight(.semibold))
                        Text("删除会同时移除本地记录、关联截图、会话和提醒，且无法撤销。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("删除全部本地记忆", role: .destructive) { model.clearAllData() }
                        .buttonStyle(.bordered)
                }
                .padding(16)
                .background(Color.red.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.red.opacity(0.2), lineWidth: 1))
            }
            .frame(maxWidth: 1_100, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("隐私与模型")
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
                let excluded = Set(excludedApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                activeConfiguration = configuration
                model.saveModelConnection(configuration: configuration, apiKey: key, excludedBundleIdentifiers: excluded)
                if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    savedKeyExists = true
                }
            }
        }
    }

    private var settingsHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 5) {
                Text("隐私与模型")
                    .font(.system(size: 26, weight: .semibold))
                Text("统一管理本地数据边界、模型使用和每日总结。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Label(model.state.privacy.screenCapturePaused ? "采集已暂停" : "本地数据保护中", systemImage: model.state.privacy.screenCapturePaused ? "pause.circle.fill" : "lock.fill")
                Label(model.state.privacy.cloudUseEnabled ? "已允许脱敏文本" : "仅本地模式", systemImage: model.state.privacy.cloudUseEnabled ? "cloud.fill" : "desktopcomputer")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary, lineWidth: 1))
    }

    private func settingsCard<Content: View>(title: String, icon: String, tint: Color = .accentColor, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(tint)
            content()
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary, lineWidth: 1))
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
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("编辑模型连接").font(.title2.weight(.semibold))
                    Text("配置与 OpenAI 或 Anthropic 协议兼容的模型服务")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(savedKeyExists ? "凭据已配置" : "等待配置", systemImage: savedKeyExists ? "checkmark.shield.fill" : "key.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(savedKeyExists ? .green : .orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background((savedKeyExists ? Color.green : Color.orange).opacity(0.10), in: Capsule())
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
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.quaternary, lineWidth: 1))

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
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(revealsAPIKey ? "隐藏 API Key" : "显示 API Key")
                            }
                        }
                    }
                    .padding(16)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.quaternary, lineWidth: 1))

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
                                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存并用于问一问", action: save)
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
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func connectionField<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .padding(.horizontal, 12)
                .frame(height: 40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1))
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
        case .success: return .green
        case .failure: return .red
        case .none: return connectionChanged ? .orange : .green
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
