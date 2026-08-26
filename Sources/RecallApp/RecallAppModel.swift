import Foundation
import RecallKit
import SwiftUI

enum ReminderDiscoveryStatus: Equatable {
    case idle
    case searching(scannedRecordCount: Int)
    case completed(scannedRecordCount: Int, discoveredCount: Int, completedAt: Date)
}

@MainActor
final class RecallAppModel: ObservableObject {
    @Published var state = RecallState()
    @Published var isRecording = false
    @Published var isThinking = false
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published private(set) var enterKeyMonitorStatus: GlobalEnterKeyRecorderStatus = .disabled
    @Published private(set) var assistantMessageNeedingAnimationID: UUID?
    @Published private(set) var diagnosticEntries: [RecallDiagnosticEntry]
    @Published private(set) var reminderDeliveryStates: [UUID: ReminderDeliveryState] = [:]
    @Published private(set) var reminderDiscoveryStatus: ReminderDiscoveryStatus = .idle

    let storage: RecallStorage
    private let store: FileMemoryStore
    private let pipeline: CapturePipeline
    private let assistant: MemoryAssistant
    private let reminderExtractor = ReminderExtractor()
    private let dailySummaryGenerator = DailySummaryGenerator()
    private let notificationScheduler = LocalNotificationScheduler()
    private let enterKeyRecorder = GlobalEnterKeyRecorder()
    private var dailySummaryTimer: Timer?
    private var isGeneratingDailySummary = false
    private let diagnosticLog: RecallDiagnosticLogStore

    init() {
        do {
            let storage = try RecallStorage()
            self.storage = storage
            self.diagnosticLog = RecallDiagnosticLogStore(storage: storage)
            self.diagnosticEntries = diagnosticLog.entries
            self.store = try FileMemoryStore(storage: storage)
            self.pipeline = CapturePipeline(store: store, storage: storage)
            self.assistant = MemoryAssistant(store: store)
            recordDiagnostic(.info, source: "App", message: "应用已启动")
            Task { await refresh() }
        } catch {
            fatalError("无法初始化本地记忆库：\(error.localizedDescription)")
        }
    }


    func refresh() async {
        state = await store.snapshot()
        updateEnterKeyRecorder()
        await refreshReminderDeliveryStates()
        armDailySummaryTimer()
        generateMissedDailySummaryIfNeeded()
    }

    func verifyReminderDelivery() {
        Task {
            await refreshReminderDeliveryStates()
            let scheduled = state.reminders.filter { $0.status == .scheduled }
            let counts = scheduled.reduce(into: (pending: 0, delivered: 0, notFound: 0)) { result, reminder in
                switch reminderDeliveryStates[reminder.id] {
                case .pending: result.pending += 1
                case .delivered: result.delivered += 1
                case .notFound, .none: result.notFound += 1
                }
            }
            if scheduled.isEmpty {
                noticeMessage = "当前没有已安排的提醒。"
            } else {
                noticeMessage = "已核验系统通知：待投递 \(counts.pending) 项，已推送 \(counts.delivered) 项，未在系统队列中找到 \(counts.notFound) 项。"
            }
        }
    }

    private func refreshReminderDeliveryStates() async {
        let scheduled = state.reminders.filter { $0.status == .scheduled }
        guard !scheduled.isEmpty else {
            reminderDeliveryStates = [:]
            return
        }
        do {
            let nextStates = try await notificationScheduler.deliveryStates(for: scheduled)
            let missingIDs = nextStates.compactMap { $0.value == .notFound ? $0.key.uuidString : nil }.sorted()
            if !missingIDs.isEmpty, missingIDs != reminderDeliveryStates.compactMap({ $0.value == .notFound ? $0.key.uuidString : nil }).sorted() {
                recordDiagnostic(.warning, source: "Reminders", message: "已安排提醒未出现在系统通知队列", metadata: ["count": "\(missingIDs.count)"])
            }
            reminderDeliveryStates = nextStates
        } catch {
            reminderDeliveryStates = [:]
            recordDiagnostic(.warning, source: "Reminders", message: "无法核验系统通知队列", metadata: ["error": String(describing: type(of: error))])
        }
    }

    func clearDiagnosticLog() {
        diagnosticLog.clear()
        diagnosticEntries = diagnosticLog.entries
    }

    private func recordDiagnostic(
        _ level: RecallDiagnosticLevel,
        source: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        diagnosticLog.record(level, source: source, message: message, metadata: metadata)
        diagnosticEntries = diagnosticLog.entries
    }

    private func updateEnterKeyRecorder() {
        guard let rule = state.rules.first(where: { $0.template == .enterKeyTrigger }) else {
            enterKeyRecorder.stop()
            enterKeyMonitorStatus = .disabled
            return
        }
        let shouldMonitor = rule.isEnabled && !state.privacy.screenCapturePaused
        let nextStatus = enterKeyRecorder.update(isEnabled: shouldMonitor) { [weak self] in
            guard let self else { return }
            guard let currentRule = self.state.rules.first(where: { $0.template == .enterKeyTrigger }), currentRule.isEnabled else { return }
            self.recordDiagnostic(.info, source: "GlobalEnter", message: "收到其他应用的 Enter 事件", metadata: ["scope": currentRule.scope.rawValue])
            self.record(rule: currentRule, diagnosticSource: "GlobalEnter")
        }
        if enterKeyMonitorStatus != nextStatus {
            recordDiagnostic(
                nextStatus == .inputMonitoringPermissionRequired ? .warning : .info,
                source: "GlobalEnter",
                message: "跨应用 Enter 监听状态更新：\(nextStatus.title)",
                metadata: ["ruleEnabled": rule.isEnabled ? "true" : "false", "capturePaused": state.privacy.screenCapturePaused ? "true" : "false"]
            )
        }
        enterKeyMonitorStatus = nextStatus
    }

    func updateRule(_ updatedRule: EventRule) {
        var rules = state.rules
        guard let index = rules.firstIndex(where: { $0.id == updatedRule.id }) else { return }
        rules[index] = updatedRule
        state.rules = rules
        updateEnterKeyRecorder()
        persistRules(rules)
        if updatedRule.template == .enterKeyTrigger && updatedRule.isEnabled {
            switch enterKeyMonitorStatus {
            case .monitoring:
                noticeMessage = "Enter 键记录已启用，正在监听 Recall 以外应用中的 Enter 键。"
            case .inputMonitoringPermissionRequired:
                noticeMessage = "Enter 键记录已启用，但需要在系统设置中允许 Recall 的输入监控和辅助功能权限。"
            case .disabled:
                break
            }
        }
        if updatedRule.template == .dailyReview {
            noticeMessage = updatedRule.isEnabled
                ? "“定时个人回顾”事件可手动记录；自动每日总结请在“隐私与模型”中单独开启。"
                : "已关闭手动定时个人回顾事件。"
        }
    }

    func checkEnterKeyMonitor() {
        recordDiagnostic(.info, source: "GlobalEnter", message: "用户请求检查跨应用权限")
        enterKeyRecorder.requestRequiredPermissions()
        updateEnterKeyRecorder()
        switch enterKeyMonitorStatus {
        case .monitoring:
            noticeMessage = "键盘输入监控已可用：Recall 正在监听其他应用中的 Enter 键。"
        case .inputMonitoringPermissionRequired:
            noticeMessage = "尚未获得跨应用键盘监听权限。请在系统设置 → 隐私与安全性中允许 Recall 的“输入监控”和“辅助功能”，然后回到此处再次检查。"
        case .disabled:
            noticeMessage = "请先启用“Enter 键触发记录”规则。"
        }
    }

    func toggleRule(_ rule: EventRule, isEnabled: Bool) {
        var updated = rule
        updated.isEnabled = isEnabled
        updateRule(updated)
    }

    private func persistRules(_ rules: [EventRule]) {
        Task {
            do {
                try await store.updateRules(rules)
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func requestScreenRecordingAccess() {
        let granted = ScreenCaptureService().requestScreenRecordingAccess()
        recordDiagnostic(granted ? .info : .warning, source: "ScreenCapture", message: granted ? "屏幕权限检查通过" : "屏幕权限检查未通过")
        noticeMessage = granted ? "屏幕记录权限已可用。" : "请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许 Recall。"
    }

    func record(rule: EventRule, userText: String? = nil, diagnosticSource: String = "Capture") {
        isRecording = true
        recordDiagnostic(
            .info,
            source: diagnosticSource,
            message: "开始记录",
            metadata: ["eventTemplate": rule.template.rawValue, "scope": rule.scope.rawValue]
        )
        Task {
            defer { isRecording = false }
            do {
                let resolvedText = rule.template == .dailyReview ? makeDailyReviewText() : userText
                let record = try await pipeline.record(using: rule, userText: resolvedText)
                await refresh()
                recordDiagnostic(
                    .info,
                    source: diagnosticSource,
                    message: "记录已写入时间线",
                    metadata: ["eventTemplate": record.eventTemplate.rawValue, "hasScreenshot": record.imageRelativePath == nil ? "false" : "true"]
                )
                noticeMessage = "已记录：\(record.summary ?? "无可提取文本")"
                if rule.participatesInReminders {
                    proposeReminders()
                }
            } catch CapturePipelineError.screenRecordingPermissionRequired {
                recordDiagnostic(.warning, source: diagnosticSource, message: "屏幕权限不可用", metadata: ["eventTemplate": rule.template.rawValue])
                // 记录失败不应阻塞其他本地功能；提醒发现只读取已有记录，无需此权限。
                noticeMessage = "未能截图记录：如需保存屏幕内容，请在系统设置中允许屏幕与系统音频录制。"
            } catch {
                recordDiagnostic(.error, source: diagnosticSource, message: "记录失败", metadata: ["eventTemplate": rule.template.rawValue, "error": recallSafeErrorCode(error)])
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteCapture(_ capture: CaptureRecord) {
        Task {
            do {
                try await pipeline.removeCapture(capture)
                await refresh()
                noticeMessage = "已删除该记录及其关联截图。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func recordEnterTriggeredChatSend(_ text: String) {
        guard let rule = state.rules.first(where: { $0.template == .enterKeyTrigger }) else {
            recordDiagnostic(.error, source: "ChatEnter", message: "未找到 Enter 事件规则")
            return
        }
        guard rule.isEnabled else {
            recordDiagnostic(.warning, source: "ChatEnter", message: "Enter 发送未记录：规则未启用")
            return
        }
        guard !state.privacy.screenCapturePaused else {
            recordDiagnostic(.warning, source: "ChatEnter", message: "Enter 发送未记录：采集已暂停")
            return
        }
        recordDiagnostic(.info, source: "ChatEnter", message: "收到问一问 Enter 发送", metadata: ["scope": CaptureScope.textOnly.rawValue])
        var textOnlyRule = rule
        textOnlyRule.scope = .textOnly
        textOnlyRule.retainImageDays = 0
        record(rule: textOnlyRule, userText: text, diagnosticSource: "ChatEnter")
    }

    func ask(_ question: String) {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isThinking = true
        Task {
            defer { isThinking = false }
            do {
                let assistantMessage = try await assistant.ask(question)
                assistantMessageNeedingAnimationID = assistantMessage.id
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func finishAssistantMessageAnimation(id: UUID) {
        guard assistantMessageNeedingAnimationID == id else { return }
        assistantMessageNeedingAnimationID = nil
    }

    func proposeReminders() {
        // 仅检索已经持久化在 state 中的 OCR 文本；不会调用截图管线，也不需要屏幕录制权限。
        if case .searching = reminderDiscoveryStatus { return }
        errorMessage = nil
        let captures = state.captures
        let existingReminders = state.reminders
        reminderDiscoveryStatus = .searching(scannedRecordCount: captures.count)

        Task {
            // 让“正在检索”状态先渲染，再对所有本地记录执行候选提取与去重。
            await Task.yield()
            let newCandidates = reminderExtractor.candidates(from: captures, existing: existingReminders)
            let completedAt = Date.now
            guard !newCandidates.isEmpty else {
                reminderDiscoveryStatus = .completed(
                    scannedRecordCount: captures.count,
                    discoveredCount: 0,
                    completedAt: completedAt
                )
                noticeMessage = captures.isEmpty
                    ? "当前还没有可检索的本地记忆。"
                    : "已检索 \(captures.count) 条本地记录，暂未发现新的待确认提醒。"
                return
            }
            do {
                try await store.replaceReminders(newCandidates + existingReminders)
                await refresh()
                reminderDiscoveryStatus = .completed(
                    scannedRecordCount: captures.count,
                    discoveredCount: newCandidates.count,
                    completedAt: completedAt
                )
                noticeMessage = "已检索 \(captures.count) 条本地记录，发现 \(newCandidates.count) 项待确认提醒。"
            } catch {
                reminderDiscoveryStatus = .idle
                errorMessage = error.localizedDescription
            }
        }
    }

    func approveReminder(_ reminder: ReminderCandidate, dueAt: Date) {
        guard dueAt > Date.now else {
            errorMessage = "请为提醒选择一个未来时间。"
            return
        }
        Task {
            do {
                var updated = reminder
                updated.dueAt = dueAt
                let granted = try await notificationScheduler.requestAuthorization()
                guard granted else {
                    throw ReminderNotificationError.authorizationRequired
                }
                try await notificationScheduler.schedule(updated)
                updated.status = .scheduled
                try await store.updateReminder(updated)
                await refresh()
                guard reminderDeliveryStates[updated.id] == .pending else {
                    throw ReminderNotificationError.notificationSchedulingFailed
                }
                noticeMessage = "提醒已写入 macOS 通知队列，将在 \(dueAt.formatted(date: .abbreviated, time: .shortened)) 推送。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func dismissReminder(_ reminder: ReminderCandidate) {
        Task {
            do {
                let wasScheduled = reminder.status == .scheduled
                var updated = reminder
                updated.status = .dismissed
                notificationScheduler.cancel(updated)
                try await store.updateReminder(updated)
                await refresh()
                noticeMessage = wasScheduled ? "提醒已取消。" : "已忽略该提醒候选。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func dismissAllProposedReminders() {
        Task {
            do {
                let dismissedCount = try await store.dismissAllProposedReminders()
                await refresh()
                noticeMessage = dismissedCount > 0
                    ? "已忽略 \(dismissedCount) 项待确认提醒。"
                    : "当前没有待确认提醒。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func updatePrivacy(_ privacy: PrivacySettings) {
        state.privacy = privacy
        updateEnterKeyRecorder()
        Task {
            do {
                try await store.updatePrivacy(privacy)
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func updateDailySummarySettings(_ settings: DailySummarySettings) {
        state.dailySummarySettings = settings
        Task {
            do {
                try await store.updateDailySummarySettings(settings)
                await refresh()
                if settings.isEnabled {
                    noticeMessage = "每日总结已开启：将在每天 \(dailySummaryTimeText(settings)) 汇总前一天记录。"
                } else {
                    noticeMessage = "每日总结已关闭；已有总结会继续保留，直到你手动删除。"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func generatePreviousDaySummaryNow() {
        let previousDay = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
        generateDailySummary(for: previousDay, reason: .manual)
    }

    func deleteDailySummary(_ summary: DailySummary) {
        Task {
            do {
                try await store.deleteDailySummary(id: summary.id)
                await refresh()
                noticeMessage = "已删除该每日总结。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func updateLLM(configuration: LLMConfiguration, apiKey: String?) {
        Task {
            do {
                var updatedConfiguration = configuration
                if let apiKey, !apiKey.isEmpty {
                    updatedConfiguration.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                try await store.updateLLMConfiguration(updatedConfiguration)
                await refresh()
                noticeMessage = configuration.provider == .localOnly ? "已切换为本地摘要模式。" : "云端模型配置已保存；只有检索到的文本片段会在提问时发送。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 模型连接表单的提交入口。用户主动点击后，下一次“问一问”会直接使用此配置。
    func saveModelConnection(configuration: LLMConfiguration, apiKey: String, excludedBundleIdentifiers: Set<String>) {
        Task {
            do {
                let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                var updatedConfiguration = configuration
                if !cleanedKey.isEmpty {
                    updatedConfiguration.apiKey = cleanedKey
                }
                var privacy = state.privacy
                privacy.excludedBundleIdentifiers = excludedBundleIdentifiers
                privacy.cloudUseEnabled = true
                try await store.updatePrivacy(privacy)
                try await store.updateLLMConfiguration(updatedConfiguration)
                await refresh()
                noticeMessage = "模型连接已保存；下一次“问一问”将使用 \(updatedConfiguration.model)。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private enum DailySummaryReason {
        case scheduled
        case manual
    }

    private func generateDailySummary(for day: Date, reason: DailySummaryReason) {
        guard !isGeneratingDailySummary else { return }
        isGeneratingDailySummary = true
        isThinking = true
        let captures = state.captures
        let previousSummaries = state.dailySummaries
        let responder = dailySummaryResponder()
        Task {
            defer {
                isGeneratingDailySummary = false
                isThinking = false
            }
            do {
                let generation = try await dailySummaryGenerator.generate(
                    day: day,
                    from: captures,
                    previousSummaries: previousSummaries,
                    responder: responder
                )
                let summary = DailySummary(
                    day: day,
                    content: generation.content,
                    sourceCaptureIDs: generation.sourceCaptureIDs,
                    todos: generation.todos,
                    generationKind: generation.generationKind
                )
                try await store.upsertDailySummary(summary)
                await refresh()
                if !summary.todos.isEmpty {
                    proposeReminders()
                }
                let mode = summary.generationKind == .cloud ? "模型总结" : "本地回退摘要"
                noticeMessage = "已生成 \(day.formatted(date: .abbreviated, time: .omitted)) 的\(mode)。"
                recordDiagnostic(.info, source: "DailySummary", message: "每日总结已生成", metadata: [
                    "reason": reason == .scheduled ? "scheduled" : "manual",
                    "generation": summary.generationKind.rawValue,
                    "sourceCount": "\(summary.sourceCaptureIDs.count)",
                    "todoCount": "\(summary.todos.count)"
                ])
            } catch {
                recordDiagnostic(.error, source: "DailySummary", message: "每日总结生成失败", metadata: ["error": recallSafeErrorCode(error)])
                errorMessage = "每日总结未能生成：\(error.localizedDescription)"
            }
        }
    }

    private func dailySummaryResponder() -> (any LLMResponding)? {
        let configuration = state.llmConfiguration
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state.privacy.cloudUseEnabled,
              configuration.provider != .localOnly,
              !apiKey.isEmpty else {
            return nil
        }
        return CompatibleLLM(configuration: configuration, apiKey: apiKey)
    }

    private func armDailySummaryTimer() {
        dailySummaryTimer?.invalidate()
        dailySummaryTimer = nil
        let settings = state.dailySummarySettings
        guard settings.isEnabled else { return }

        let calendar = Calendar.current
        let now = Date.now
        var nextTrigger = settings.triggerDate(on: now, calendar: calendar)
        if nextTrigger <= now {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
            nextTrigger = settings.triggerDate(on: tomorrow, calendar: calendar)
        }
        let interval = max(nextTrigger.timeIntervalSince(now), 1)
        dailySummaryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let previousDay = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
                self.generateDailySummary(for: previousDay, reason: .scheduled)
            }
        }
    }

    private func generateMissedDailySummaryIfNeeded() {
        let settings = state.dailySummarySettings
        guard settings.isEnabled, !isGeneratingDailySummary else { return }
        let now = Date.now
        guard now >= settings.triggerDate(on: now) else { return }
        let previousDay = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        guard !state.dailySummaries.contains(where: { Calendar.current.isDate($0.day, inSameDayAs: previousDay) }) else { return }
        generateDailySummary(for: previousDay, reason: .scheduled)
    }

    private func dailySummaryTimeText(_ settings: DailySummarySettings) -> String {
        String(format: "%02d:%02d", settings.hour, settings.minute)
    }

    private func makeDailyReviewText() -> String {
        let start = Calendar.current.startOfDay(for: .now)
        let todaysCaptures = state.captures.filter { $0.createdAt >= start && $0.eventTemplate != .dailyReview }
        guard !todaysCaptures.isEmpty else {
            return "每日回顾：今天还没有可汇总的显式记录。"
        }
        let lines = todaysCaptures.prefix(12).map { capture in
            let source = capture.sourceAppName ?? "未知来源"
            return "- \(source)：\(capture.summary ?? String(capture.ocrText.prefix(120)))"
        }
        return "每日回顾（\(todaysCaptures.count) 条显式记录）：\n" + lines.joined(separator: "\n")
    }

    func clearAllData() {
        let captures = state.captures
        Task {
            do {
                for capture in captures {
                    try await pipeline.removeCapture(capture)
                }
                try await store.clearDailySummaries()
                await refresh()
                noticeMessage = "已删除全部本地记忆记录。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
