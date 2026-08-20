import RecallKit
import SwiftUI

struct RecallRootView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var section: SidebarSection? = .timeline
    @State private var showingRecordSheet = false

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("记忆") {
                    Label("时间线", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarSection.timeline)
                    Label("问一问", systemImage: "bubble.left.and.bubble.right")
                        .tag(SidebarSection.chat)
                    Label("提醒", systemImage: "bell.badge")
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingRecordSheet = true
                    } label: {
                        Label("记录此刻", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .disabled(model.isRecording || model.state.privacy.screenCapturePaused)
                }
            }
        } detail: {
            Group {
                switch section ?? .timeline {
                case .timeline: TimelineView()
                case .chat: ChatView()
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
            }
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
}

private enum SidebarSection: Hashable {
    case timeline, chat, reminders, rules, privacy
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

    private var captures: [CaptureRecord] {
        guard !searchText.isEmpty else { return model.state.captures }
        return MemorySearchEngine().search(MemorySearchQuery(text: searchText), in: model.state.captures).map(\.capture)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("记忆时间线")
                        .font(.title2.weight(.semibold))
                    Text("每条记录均可追溯、删除，并默认仅存在本机。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("检查屏幕权限") { model.requestScreenRecordingAccess() }
            }
            .padding()
            TextField("搜索本地记忆", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 10)

            if captures.isEmpty {
                ContentUnavailableView("还没有记忆记录", systemImage: "tray", description: Text("使用右上角“记录此刻”保存第一个工作节点。"))
            } else {
                List(captures) { capture in
                    CaptureRow(capture: capture)
                        .contextMenu {
                            Button("删除记录", role: .destructive) { model.deleteCapture(capture) }
                        }
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct CaptureRow: View {
    @EnvironmentObject private var model: RecallAppModel
    let capture: CaptureRecord

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
                    Text(capture.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let source = capture.sourceAppName { Text(source) }
                    ForEach(capture.tags.prefix(3), id: \.self) { tag in
                        Text(tag).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(role: .destructive) { model.deleteCapture(capture) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

private struct ChatView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var question = ""

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
                ChatComposer(question: $question, isSending: model.isThinking, onSend: send)
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
                        RecallMessageCard(message: message)
                            .id(message.id)
                    }
                    if model.isThinking {
                        ThinkingCard()
                    }
                }
                .frame(maxWidth: 860)
                .padding(.horizontal, 32)
                .padding(.vertical, 30)
            }
            .onChange(of: model.state.messages.count) { _, _ in
                if let last = model.state.messages.last {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        model.ask(text)
    }
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
        HStack(alignment: .top, spacing: 12) {
            if message.role != .user {
                Image(systemName: "sparkle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor, in: Circle())
            } else {
                Spacer(minLength: 80)
            }
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
                Text(message.content)
                    .textSelection(.enabled)
                    .lineSpacing(4)
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
            if message.role == .user { Spacer(minLength: 32) }
        }
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

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                TextField("向 Recall 提问", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .font(.body)
                    .onSubmit(onSend)
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
                Text("Enter 发送 · ⇧Enter 换行")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 18, y: 6)
        .padding(.horizontal, 32)
        .padding(.vertical, 18)
    }
}

private struct RemindersView: View {
    @EnvironmentObject private var model: RecallAppModel

    private var active: [ReminderCandidate] {
        model.state.reminders.filter { $0.status == .proposed || $0.status == .scheduled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("提醒候选")
                        .font(.title2.weight(.semibold))
                    Text("系统只提出候选；你确认后才会创建本地通知。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("从记录中检查") { model.proposeReminders() }
            }
            .padding()
            if active.isEmpty {
                ContentUnavailableView("暂无提醒", systemImage: "bell.slash", description: Text("可以从“待办或承诺创建”事件开始记录，或手动检查已有记录。"))
            } else {
                List(active) { reminder in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(reminder.title).font(.headline)
                            Text(reminder.detail).foregroundStyle(.secondary)
                            Text("置信度 \(Int(reminder.confidence * 100))% · \(reminder.status == .scheduled ? "已安排" : "待确认")")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if reminder.status == .proposed {
                            Button("创建提醒") { model.approveReminder(reminder) }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("忽略", role: .destructive) { model.dismissReminder(reminder) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
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

struct RecallSettingsView: View {
    var body: some View {
        PrivacyAndModelView()
            .padding()
    }
}

private struct PrivacyAndModelView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var configuration = LLMConfiguration()
    @State private var apiKey = ""
    @State private var excludedApps = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section("屏幕与数据") {
                Toggle("暂停全部屏幕采集", isOn: privacyBinding(\.screenCapturePaused))
                Toggle("保留原始截图", isOn: privacyBinding(\.retainScreenshots))
                TextField("排除的 Bundle ID（逗号分隔）", text: $excludedApps)
                Button("请求/检查屏幕录制权限") { model.requestScreenRecordingAccess() }
            }
            Section("模型会话") {
                Picker("模型类型", selection: Binding(
                    get: { configuration.provider == .anthropicCompatible ? .anthropicCompatible : .openAICompatible },
                    set: { configuration.applyDefaults(for: $0) }
                )) {
                    Text("兼容 OpenAI API").tag(LLMProviderKind.openAICompatible)
                    Text("兼容 Anthropic API").tag(LLMProviderKind.anthropicCompatible)
                }
                Toggle("允许在我提问时发送已检索的脱敏文本", isOn: privacyBinding(\.cloudUseEnabled))
                TextField("地址", text: $configuration.baseURLString)
                    .textContentType(.URL)
                TextField("模型", text: $configuration.model)
                SecureField("API Key（仅保存到钥匙串）", text: $apiKey)
                if configuration.provider == .anthropicCompatible {
                    TextField("Anthropic API 版本", text: $configuration.anthropicVersion)
                }
                Stepper("最多生成 \(configuration.maxOutputTokens) tokens", value: $configuration.maxOutputTokens, in: 256...8_192, step: 256)
                Text("地址、模型与 API Key 均可按你的兼容服务修改。调用时只会发送当前问题需要的脱敏文本、压缩摘要与最近会话窗口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("保存隐私与模型设置") {
                    var privacy = model.state.privacy
                    privacy.excludedBundleIdentifiers = Set(excludedApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                    model.updatePrivacy(privacy)
                    model.updateLLM(configuration: configuration, apiKey: apiKey)
                    apiKey = ""
                }
            }
            Section("危险操作") {
                Button("删除全部本地记忆", role: .destructive) { model.clearAllData() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("隐私与模型")
        .onAppear {
            guard !loaded else { return }
            configuration = model.state.llmConfiguration
            if configuration.provider == .localOnly {
                configuration.applyDefaults(for: .openAICompatible)
            }
            excludedApps = model.state.privacy.excludedBundleIdentifiers.sorted().joined(separator: ", ")
            loaded = true
        }
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
