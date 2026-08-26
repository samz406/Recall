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
        .overlay(alignment: .bottom) {
            if let notice = model.noticeMessage {
                NoticeBanner(text: notice) {
                    model.noticeMessage = nil
                }
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .alert("Recall 出现问题", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
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
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .lineLimit(2)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 8)
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

private struct TimelineView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var searchText = ""
    @State private var expandedDayIDs: Set<Date> = []

    private var captures: [CaptureRecord] {
        guard !searchText.isEmpty else { return model.state.captures }
        return MemorySearchEngine().search(MemorySearchQuery(text: searchText), in: model.state.captures).map(\.capture)
    }

    private var dayGroups: [TimelineDayGroup] {
        TimelineGrouping.dayGroups(for: captures)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                timelineHeader
                TextField("搜索本地记忆", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                    .padding(.bottom, 12)

                if captures.isEmpty {
                    ContentUnavailableView(
                        isSearching ? "没有匹配的本地记录" : "还没有记忆记录",
                        systemImage: isSearching ? "magnifyingglass" : "tray",
                        description: Text(isSearching ? "可尝试日期、应用名称或其他关键词。" : "使用右上角“记录此刻”保存第一个工作节点。")
                    )
                } else {
                    dayNavigator(proxy: proxy)
                    Divider()
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
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                    }
                }
            }
            .onAppear { initializeExpandedDays() }
            .onChange(of: searchText) { _, _ in
                if isSearching {
                    expandedDayIDs = Set(dayGroups.map(\.id))
                } else {
                    initializeExpandedDays()
                }
            }
            .onChange(of: dayGroups.map(\.id)) { _, _ in
                initializeExpandedDays()
            }
        }
    }

    private var timelineHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("记忆时间线")
                    .font(.title2.weight(.semibold))
                Text("按天回看你的本地记录；每条内容仍可追溯和删除。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("检查屏幕权限") { model.requestScreenRecordingAccess() }
        }
        .padding()
    }

    private func dayNavigator(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(dayGroups.prefix(10)) { group in
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            expandedDayIDs.insert(group.id)
                            proxy.scrollTo(group.id, anchor: .top)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(navigationTitle(for: group.day))
                            Text("\(group.captures.count)")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }

    private func initializeExpandedDays() {
        let availableDays = Set(dayGroups.map(\.id))
        if isSearching {
            expandedDayIDs = availableDays
        } else if expandedDayIDs.isEmpty {
            expandedDayIDs = Set(dayGroups.filter { isRecentDay($0.day) }.map(\.id))
        } else {
            expandedDayIDs.formIntersection(availableDays)
        }
    }

    private func toggle(_ day: Date) {
        if expandedDayIDs.contains(day) {
            expandedDayIDs.remove(day)
        } else {
            expandedDayIDs.insert(day)
        }
    }

    private func isRecentDay(_ day: Date) -> Bool {
        let calendar = Calendar.current
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: Date.now) ?? Date.now
        return day >= calendar.startOfDay(for: sevenDaysAgo)
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
                    onSend: { send(recordingEnterEvent: false) },
                    onEnterSend: { send(recordingEnterEvent: true) }
                ) {
                    scrollRequest += 1
                }
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
                LazyVStack(spacing: 22) {
                    ForEach(model.state.messages) { message in
                        RecallMessageCard(
                            message: message,
                            animateTyping: model.assistantMessageNeedingAnimationID == message.id,
                            onTypingProgress: { scrollRequest += 1 },
                            onTypingFinished: { model.finishAssistantMessageAnimation(id: message.id) }
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
                scrollToLatest(using: proxy)
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

    private func send(recordingEnterEvent: Bool) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        scrollRequest += 1
        if recordingEnterEvent {
            model.recordEnterTriggeredChatSend(text)
        }
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
    let animateTyping: Bool
    let onTypingProgress: () -> Void
    let onTypingFinished: () -> Void

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
                MarkdownTypewriterText(
                    markdown: message.content,
                    shouldAnimate: animateTyping,
                    onProgress: onTypingProgress,
                    onFinished: onTypingFinished
                )
            } else {
                Text(message.content)
                    .textSelection(.enabled)
                    .lineSpacing(4)
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

private struct MarkdownTypewriterText: View {
    let markdown: String
    let shouldAnimate: Bool
    let onProgress: () -> Void
    let onFinished: () -> Void
    @State private var visibleCharacterCount = 0
    @State private var animationTask: Task<Void, Never>?

    private var visibleMarkdown: String {
        guard shouldAnimate else { return markdown }
        return String(markdown.prefix(visibleCharacterCount))
    }

    var body: some View {
        Text(markdownAttributedString(from: visibleMarkdown))
            .textSelection(.enabled)
            .lineSpacing(4)
            .task(id: shouldAnimate) {
                animationTask?.cancel()
                guard shouldAnimate else {
                    visibleCharacterCount = markdown.count
                    return
                }
                visibleCharacterCount = 0
                let total = markdown.count
                let step = max(1, min(8, total / 160))
                while visibleCharacterCount < total && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    guard !Task.isCancelled else { return }
                    visibleCharacterCount = min(total, visibleCharacterCount + step)
                    onProgress()
                }
                guard !Task.isCancelled else { return }
                onFinished()
            }
            .onDisappear {
                animationTask?.cancel()
            }
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
    let onEnterSend: () -> Void
    let onJumpToLatest: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                TextField("向 Recall 提问", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .font(.body)
                    .submitLabel(.send)
                    .onKeyPress(.return) {
                        submitFromEnter()
                        return .handled
                    }
                    .onSubmit(submitFromEnter)
                Button(action: onSend) {
                    Image(systemName: isSending ? "ellipsis" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending ? Color.secondary : Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
            HStack {
                Label("回答附带记忆来源", systemImage: "checkmark.shield")
                Spacer()
                Button(action: onJumpToLatest) {
                    Label("最新", systemImage: "arrow.down.to.line.compact")
                }
                .buttonStyle(.plain)
                Text("Enter 发送并记录 · 点击箭头仅发送")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 18, y: 6)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func submitFromEnter() {
        guard !isSending, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onEnterSend()
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
                    onDelete: { model.deleteDailySummary(summary) }
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

    private var preview: String {
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
                MarkdownDocumentView(markdown: summary.content)
                    .textSelection(.enabled)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
    @State private var isConfirmingDismissAll = false

    private var proposed: [ReminderCandidate] {
        model.state.reminders.filter { $0.status == .proposed }
    }

    private var scheduled: [ReminderCandidate] {
        model.state.reminders.filter { $0.status == .scheduled }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                reminderHeader
                workflow
                if proposed.isEmpty && scheduled.isEmpty {
                    ReminderEmptyState(onDiscover: model.proposeReminders)
                } else {
                    reminderLists
                }
            }
            .frame(maxWidth: 980)
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $reminderBeingScheduled) { reminder in
            ReminderScheduleSheet(reminder: reminder) { dueAt in
                model.approveReminder(reminder, dueAt: dueAt)
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
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Label("提醒", systemImage: "bell.badge")
                    .font(.system(size: 22, weight: .semibold))
                Text("Recall 只从已有记忆中提出候选；是否提醒、何时提醒，始终由你决定。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                Button(action: model.verifyReminderDelivery) {
                    Label("核验推送状态", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Button {
                    model.proposeReminders()
                } label: {
                    Label("从记忆中发现", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var workflow: some View {
        HStack(spacing: 0) {
            ReminderWorkflowStep(number: "1", title: "发现线索", detail: "从待办、承诺与截止记录中识别")
            workflowConnector
            ReminderWorkflowStep(number: "2", title: "由你确认", detail: "检查来源后再创建提醒")
            workflowConnector
            ReminderWorkflowStep(number: "3", title: "按时通知", detail: "只投递你明确同意的事项")
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary, lineWidth: 1))
    }

    private var workflowConnector: some View {
        Image(systemName: "arrow.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 42)
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
                    ForEach(proposed) { reminder in
                        ReminderCandidateCard(reminder: reminder, isScheduled: false, deliveryState: nil, approve: {
                            reminderBeingScheduled = reminder
                        }, dismiss: {
                            model.dismissReminder(reminder)
                        })
                    }
                }
            }
            if !scheduled.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("已安排")
                            .font(.title3.weight(.semibold))
                        Text("已由 macOS 核验")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("“已推送”仅表示通知中心已接收，不代表已阅读")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(scheduled) { reminder in
                        ReminderCandidateCard(
                            reminder: reminder,
                            isScheduled: true,
                            deliveryState: model.reminderDeliveryStates[reminder.id],
                            approve: {},
                            dismiss: { model.dismissReminder(reminder) }
                        )
                    }
                }
            }
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
    let onDiscover: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bell.and.waves.left.and.right")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(width: 72, height: 72)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 22))
            VStack(spacing: 7) {
                Text("还没有待确认的提醒")
                    .font(.title2.weight(.semibold))
                Text("你可以让 Recall 检查已有记忆中的待办、承诺和截止事项；它只会提出候选，不会自动打扰你。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
            }
            Button(action: onDiscover) {
                Label("从记忆中发现提醒", systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            Divider().padding(.vertical, 4)
            HStack(spacing: 22) {
                ReminderFeature(icon: "checkmark.circle", title: "识别待办", detail: "例如“明天回复客户”")
                ReminderFeature(icon: "person.crop.circle.badge.clock", title: "关联来源", detail: "查看它来自哪条记忆")
                ReminderFeature(icon: "hand.tap", title: "由你决定", detail: "确认后才安排通知")
            }
        }
        .padding(38)
        .frame(maxWidth: 760)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.quaternary, lineWidth: 1))
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
                Text("设置提醒时间")
                    .font(.title2.weight(.semibold))
                Text(reminder.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let suggestedDate = reminder.dueAt {
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
                Button("确认并创建") {
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

private struct ReminderCandidateCard: View {
    let reminder: ReminderCandidate
    let isScheduled: Bool
    let deliveryState: ReminderDeliveryState?
    let approve: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: isScheduled ? "bell.fill" : "bell.badge")
                .foregroundStyle(isScheduled ? Color.green : Color.accentColor)
                .frame(width: 36, height: 36)
                .background((isScheduled ? Color.green : Color.accentColor).opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(reminder.title).font(.headline)
                Text(reminder.detail).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Label("来源 \(reminder.sourceCaptureIDs.count) 条记忆", systemImage: "link")
                    if let dueAt = reminder.dueAt {
                        Label(
                            isScheduled ? dueAt.formatted(date: .abbreviated, time: .shortened) : "建议：\(dueAt.formatted(date: .abbreviated, time: .shortened))",
                            systemImage: "calendar"
                        )
                    } else {
                        Label("创建前选择时间", systemImage: "calendar.badge.clock")
                    }
                    if !isScheduled {
                        Text("可信度 \(Int(reminder.confidence * 100))%")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                if isScheduled {
                    ReminderDeliveryBadge(state: deliveryState)
                }
            }
            Spacer()
            if isScheduled {
                VStack(alignment: .trailing, spacing: 8) {
                    Text(deliveryState == .delivered ? "已推送" : "已安排")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(deliveryState == .notFound ? .orange : .green)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background((deliveryState == .notFound ? Color.orange : Color.green).opacity(0.10), in: Capsule())
                    Button("取消提醒", role: .destructive, action: dismiss)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            } else {
                VStack(alignment: .trailing, spacing: 8) {
                    Button("选择时间并创建", action: approve)
                        .buttonStyle(.borderedProminent)
                    Button("忽略", role: .destructive, action: dismiss)
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
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("隐私与模型")
                        .font(.system(size: 26, weight: .semibold))
                    Text("管理本地数据边界，并配置“问一问”实际调用的模型连接。")
                        .foregroundStyle(.secondary)
                }

                settingsCard(title: "屏幕与数据", icon: "lock.shield") {
                    Toggle("暂停全部屏幕采集", isOn: privacyBinding(\.screenCapturePaused))
                    Toggle("保留原始截图", isOn: privacyBinding(\.retainScreenshots))
                    VStack(alignment: .leading, spacing: 7) {
                        Text("排除的 Bundle ID")
                            .font(.subheadline.weight(.medium))
                        TextField("例如：com.apple.MobileSMS, com.apple.Passwords", text: $excludedApps)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("请求/检查屏幕录制权限") { model.requestScreenRecordingAccess() }
                        .buttonStyle(.bordered)
                }

                settingsCard(title: "模型连接", icon: "cpu") {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: activeConfiguration.provider == .anthropicCompatible ? "a.circle.fill" : "o.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 42, height: 42)
                            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(activeConfiguration.provider.title)
                                .font(.headline)
                            Text(activeConfiguration.model)
                                .font(.subheadline.weight(.medium))
                            Text(activeConfiguration.baseURLString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        if savedKeyExists {
                            Label("Key 已保存", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("尚未配置 Key", systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Text("点击下方按钮会打开独立的原生编辑窗口。地址、模型和 API Key 都可以直接输入；保存后立即用于“问一问”。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Toggle("允许问一问发送已检索的脱敏文本", isOn: privacyBinding(\.cloudUseEnabled))
                        Spacer()
                        Button("编辑模型连接") { isEditingModelConnection = true }
                            .buttonStyle(.borderedProminent)
                    }
                }

                settingsCard(title: "每日总结", icon: "calendar.badge.clock", tint: .indigo) {
                    Toggle("每天自动总结前一天的记录", isOn: dailySummaryEnabledBinding)
                    DatePicker(
                        "执行时间",
                        selection: dailySummaryTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                    .datePickerStyle(.field)
                    .disabled(!model.state.dailySummarySettings.isEnabled)
                    Text("到达设定时间后，Recall 会汇总前一天已有的显式记录并保存到“每日总结”。若已允许云端文本使用且配置 API Key，会发送经过脱敏和长度裁剪的相关文本；否则保存本地回退摘要。应用未运行期间不会在后台发起模型请求，下次打开且已过设定时间时会补生成一次。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsCard(title: "本地诊断", icon: "stethoscope", tint: .orange) {
                    Text("仅记录 Recall 自身的权限状态、事件模板、操作结果和错误代码，最多保留 200 条。不记录 API Key、聊天正文、OCR 文本或截图。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Label("当前 \(model.diagnosticEntries.count) 条", systemImage: "list.bullet.rectangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("查看异常与状态日志") { isShowingDiagnostics = true }
                            .buttonStyle(.bordered)
                    }
                }

                settingsCard(title: "危险操作", icon: "exclamationmark.triangle", tint: .red) {
                    Text("删除会同时移除本地记录、关联截图、会话和提醒；此操作无法撤销。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("删除全部本地记忆", role: .destructive) { model.clearAllData() }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 38)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
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
        _apiKey = State(initialValue: configuration.apiKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("编辑模型连接").font(.title2.weight(.semibold))
                    Text("直接输入服务地址、模型名称和 API Key。保存后将在下一次“问一问”中使用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Form {
                Section("模型类型") {
                    Picker("模型类型", selection: $provider) {
                        Text("兼容 OpenAI API").tag(LLMProviderKind.openAICompatible)
                        Text("兼容 Anthropic API").tag(LLMProviderKind.anthropicCompatible)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section("连接信息") {
                    TextField("API 地址", text: $baseURL)
                        .focused($focusedField, equals: .baseURL)
                    TextField("模型名称", text: $modelName)
                        .focused($focusedField, equals: .model)
                    TextField("API Key", text: $apiKey)
                        .focused($focusedField, equals: .apiKey)
                }
                Section("连接验证") {
                    Button(isTestingConnection ? "正在测试…" : "测试当前 Key") { testConnection() }
                        .disabled(isTestingConnection || normalizedAPIKey.isEmpty)
                    if let connectionStatus {
                        switch connectionStatus {
                        case .success(let message):
                            Label(message, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .failure(let message):
                            Text(message)
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    } else {
                        Text("请先粘贴 Key 并测试连接。测试成功后再保存，避免无效 Key 覆盖当前可用连接。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存并用于问一问", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !maySaveConnection)
            }
            .padding(16)
        }
        .frame(width: 620, height: 440)
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
    }

    private var normalizedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var maySaveConnection: Bool {
        if normalizedAPIKey.isEmpty { return savedKeyExists }
        if case .success = connectionStatus { return true }
        return false
    }

    private func makeConfiguration() -> LLMConfiguration {
        LLMConfiguration(
            provider: provider,
            baseURLString: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: normalizedAPIKey,
            anthropicVersion: initialConfiguration.anthropicVersion,
            maxOutputTokens: initialConfiguration.maxOutputTokens
        )
    }

    private func testConnection() {
        guard !normalizedAPIKey.isEmpty else { return }
        isTestingConnection = true
        connectionStatus = nil
        let configuration = makeConfiguration()
        let key = normalizedAPIKey
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
