import Foundation
import RecallKit
import SwiftUI

enum ReminderDiscoveryStatus: Equatable {
    case idle
    case searching(eligibleRecordCount: Int, analyzingRecordCount: Int)
    case completed(eligibleRecordCount: Int, analyzedRecordCount: Int, discoveredCount: Int, completedAt: Date)
}

extension Notification.Name {
    static let recallReminderAction = Notification.Name("im.recall.app.reminder-action")
    static let recallOpenReminders = Notification.Name("im.recall.app.open-reminders")
}

@MainActor
final class RecallAppModel: ObservableObject {
    @Published var state = RecallState()
    @Published var isRecording = false
    @Published var isThinking = false
    @Published var noticeMessage: String?
    @Published private(set) var enterKeyMonitorStatus: GlobalEnterKeyRecorderStatus = .disabled
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
    private var reminderDiscoveryTimer: Timer?
    private var isGeneratingDailySummary = false
    private var pendingDailySummaries: [(day: Date, reason: DailySummaryReason)] = []
    private let diagnosticLog: RecallDiagnosticLogStore
    private var reminderActionObserver: NSObjectProtocol?

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
            reminderActionObserver = NotificationCenter.default.addObserver(
                forName: .recallReminderAction,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let idText = notification.userInfo?["reminderID"] as? String,
                      let id = UUID(uuidString: idText),
                      let action = notification.userInfo?["action"] as? String else { return }
                Task { @MainActor [weak self] in self?.handleReminderNotificationAction(id: id, action: action) }
            }
            Task {
                await refresh()
                try? notificationScheduler.configureReminderActions()
                discoverReminders(force: false, announce: false)
                armReminderDiscoveryTimer()
            }
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

    /// 前台运行期间周期性处理新增记录；内容哈希检查点保证未变化的记录不会被重复分析。
    private func armReminderDiscoveryTimer() {
        reminderDiscoveryTimer?.invalidate()
        reminderDiscoveryTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.discoverReminders(force: false, announce: false)
            }
        }
    }

    func verifyReminderDelivery() {
        Task {
            await refreshReminderDeliveryStates()
            let scheduled = state.reminders.filter { $0.status == .scheduled || $0.status == .snoozed }
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
        let scheduled = state.reminders.filter { $0.status == .scheduled || $0.status == .snoozed }
        guard !scheduled.isEmpty else {
            reminderDeliveryStates = [:]
            return
        }
        do {
            let nextStates = try await notificationScheduler.deliveryStates(for: scheduled)
            let missingIDs = nextStates.compactMap { id, value -> String? in
                guard value == .notFound,
                      let reminder = scheduled.first(where: { $0.id == id }),
                      (reminder.dueAt ?? .distantPast) > .now else { return nil }
                return id.uuidString
            }.sorted()
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

    private func recordError(_ error: Error, source: String, message: String) {
        recordDiagnostic(.error, source: source, message: message, metadata: ["error": recallSafeErrorCode(error)])
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
                discoverReminders(force: false, announce: false)
            } catch {
                recordError(error, source: "Rules", message: "保存记录规则失败")
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
                    discoverReminders(force: false, announce: false)
                }
            } catch CapturePipelineError.screenRecordingPermissionRequired {
                recordDiagnostic(.warning, source: diagnosticSource, message: "屏幕权限不可用", metadata: ["eventTemplate": rule.template.rawValue])
                // 记录失败不应阻塞其他本地功能；提醒发现只读取已有记录，无需此权限。
                noticeMessage = "未能截图记录：如需保存屏幕内容，请在系统设置中允许屏幕与系统音频录制。"
            } catch {
                recordDiagnostic(.error, source: diagnosticSource, message: "记录失败", metadata: ["eventTemplate": rule.template.rawValue, "error": recallSafeErrorCode(error)])
            }
        }
    }

    func deleteCapture(_ capture: CaptureRecord) {
        let derivedReminders = state.reminders.filter { $0.sourceCaptureIDs.contains(capture.id) }
        Task {
            do {
                notificationScheduler.cancelAll(derivedReminders)
                try await pipeline.removeCapture(capture)
                await refresh()
                noticeMessage = "已删除该记录及其关联截图。"
            } catch {
                recordError(error, source: "Capture", message: "删除记录失败")
            }
        }
    }

    func ask(_ question: String) {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isThinking = true
        Task {
            defer { isThinking = false }
            do {
                _ = try await assistant.ask(question)
                await refresh()
            } catch {
                recordDiagnostic(.error, source: "Chat", message: "问一问请求失败", metadata: ["error": recallSafeErrorCode(error)])
            }
        }
    }

    func proposeReminders() {
        discoverReminders(force: true, announce: true)
    }

    /// 后台仅分析已经持久化且用户允许参与提醒的文本，不截图、不读取其他应用，也不调用云端模型。
    func discoverReminders(force: Bool, announce: Bool = true) {
        if case .searching = reminderDiscoveryStatus { return }
        let participatingTemplates = Set(
            state.rules
                .filter(\.participatesInReminders)
                .map(\.template)
        )
        let oldestRelevantDate = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .distantPast
        let eligibleCaptures = state.captures.filter {
            participatingTemplates.contains($0.eventTemplate) && $0.createdAt >= oldestRelevantDate
        }
        let checkpoint = state.reminderDiscoveryCheckpoint
        let captures = force ? eligibleCaptures : eligibleCaptures.filter {
            checkpoint.processedCaptureHashes[$0.id.uuidString] != $0.contentHash
        }
        reminderDiscoveryStatus = .searching(
            eligibleRecordCount: eligibleCaptures.count,
            analyzingRecordCount: captures.count
        )

        Task {
            await Task.yield()
            let extractor = reminderExtractor
            let blockingHistory = state.reminders.filter { $0.status != .proposed }
            let extractedCandidates = await Task.detached(priority: .userInitiated) {
                extractor.candidates(from: captures, existing: blockingHistory)
            }.value
            let completedAt = Date.now
            do {
                let learningProfile = state.reminderLearningProfile
                let newCandidates = extractedCandidates.compactMap { candidate -> ReminderCandidate? in
                    var adjusted = candidate
                    adjusted.confidence = min(
                        max(candidate.confidence + learningProfile.confidenceAdjustment(for: reminderSemanticKey(candidate)), 0),
                        0.99
                    )
                    let isExplicit = candidate.detail.hasPrefix("明确提醒") || candidate.detail.hasPrefix("明确待办")
                    return adjusted.confidence >= 0.62 || isExplicit ? adjusted : nil
                }
                let merged = extractor.merging(newCandidates, into: state.reminders, now: completedAt)
                let retained = merged.filter { reminder in
                    switch reminder.status {
                    case .dismissed:
                        return completedAt.timeIntervalSince(reminder.dismissedUntil ?? reminder.updatedAt) < 90 * 86_400
                    case .completed, .cancelled:
                        return completedAt.timeIntervalSince(reminder.completedAt ?? reminder.updatedAt) < 180 * 86_400
                    default:
                        return true
                    }
                }.prefix(1_000).map { $0 }
                var nextCheckpoint = checkpoint
                nextCheckpoint.processedCaptureHashes = Dictionary(uniqueKeysWithValues: eligibleCaptures.map { ($0.id.uuidString, $0.contentHash) })
                nextCheckpoint.lastRunAt = completedAt
                nextCheckpoint.eligibleRecordCount = eligibleCaptures.count
                nextCheckpoint.analyzedRecordCount = captures.count
                nextCheckpoint.discoveredCount = newCandidates.count
                try await store.commitReminderDiscovery(reminders: retained, checkpoint: nextCheckpoint)
                await refresh()
                reminderDiscoveryStatus = .completed(
                    eligibleRecordCount: eligibleCaptures.count,
                    analyzedRecordCount: captures.count,
                    discoveredCount: newCandidates.count,
                    completedAt: completedAt
                )
                if announce {
                    noticeMessage = newCandidates.isEmpty
                        ? "已分析 \(captures.count) 条新增记录，暂未发现新的提醒候选。"
                        : "已分析 \(captures.count) 条记录，发现 \(newCandidates.count) 项待确认提醒。"
                }
            } catch {
                reminderDiscoveryStatus = .idle
                recordError(error, source: "Reminders", message: "提醒发现失败")
            }
        }
    }

    func approveReminder(_ reminder: ReminderCandidate, dueAt: Date, recurrence: ReminderRecurrence = .none) {
        guard dueAt > Date.now else {
            recordDiagnostic(.warning, source: "Reminders", message: "提醒时间不是未来时间")
            return
        }
        Task {
            do {
                var updated = reminder
                updated.dueAt = dueAt
                updated.recurrence = recurrence
                updated.scheduledAt = .now
                updated.updatedAt = .now
                updated.status = .scheduled
                let granted = try await notificationScheduler.requestAuthorization()
                guard granted else {
                    throw ReminderNotificationError.authorizationRequired
                }
                try await notificationScheduler.schedule(updated)
                var learningProfile = state.reminderLearningProfile
                learningProfile.record(
                    .confirmed(hour: Calendar.current.component(.hour, from: dueAt)),
                    semanticKey: reminderSemanticKey(updated)
                )
                do {
                    try await store.updateReminder(updated, learningProfile: learningProfile)
                } catch {
                    notificationScheduler.cancel(updated)
                    throw error
                }
                await refresh()
                guard reminderDeliveryStates[updated.id] == .pending else {
                    throw ReminderNotificationError.notificationSchedulingFailed
                }
                noticeMessage = "提醒已写入 macOS 通知队列，将在 \(dueAt.formatted(date: .abbreviated, time: .shortened)) 推送。"
            } catch {
                recordError(error, source: "Reminders", message: "安排提醒失败")
            }
        }
    }

    func createReminder(title: String, detail: String, dueAt: Date, recurrence: ReminderRecurrence) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, dueAt > .now else { return }
        let reminder = ReminderCandidate(
            title: cleanTitle,
            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines),
            dueAt: dueAt,
            sourceCaptureIDs: [],
            confidence: 1,
            status: .proposed,
            origin: .manual,
            recurrence: recurrence,
            semanticKey: String(
                cleanTitle
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .filter { $0.isLetter || $0.isNumber }
            )
        )
        approveReminder(reminder, dueAt: dueAt, recurrence: recurrence)
    }

    func dismissReminder(_ reminder: ReminderCandidate) {
        Task {
            do {
                var updated = reminder
                if reminder.status == .proposed {
                    updated.status = .dismissed
                    updated.dismissedUntil = Calendar.current.date(byAdding: .day, value: 30, to: .now)
                } else {
                    updated.status = .cancelled
                }
                updated.updatedAt = .now
                var learningProfile = state.reminderLearningProfile
                if reminder.status == .proposed {
                    learningProfile.record(.dismissed, semanticKey: reminderSemanticKey(updated))
                }
                try await store.updateReminder(updated, learningProfile: learningProfile)
                notificationScheduler.cancel(updated)
                await refresh()
                noticeMessage = reminder.status == .proposed ? "已忽略该候选，30 天内不会重复建议。" : "提醒已取消。"
            } catch {
                recordError(error, source: "Reminders", message: "更新提醒状态失败")
            }
        }
    }

    func completeReminder(_ reminder: ReminderCandidate) {
        Task {
            do {
                var updated = reminder
                var learningProfile = state.reminderLearningProfile
                learningProfile.record(.completed, semanticKey: reminderSemanticKey(updated))
                if let currentDueAt = reminder.dueAt,
                   reminder.recurrence != .none,
                   let nextDueAt = reminder.recurrence.nextDate(after: max(currentDueAt, .now)) {
                    updated.dueAt = nextDueAt
                    updated.status = .scheduled
                    updated.completedAt = .now
                    updated.updatedAt = .now
                    try await notificationScheduler.schedule(updated)
                    do {
                        try await store.updateReminder(updated, learningProfile: learningProfile)
                    } catch {
                        notificationScheduler.cancel(updated)
                        throw error
                    }
                    noticeMessage = "本次已完成，下次将在 \(nextDueAt.formatted(date: .abbreviated, time: .shortened)) 提醒。"
                } else {
                    updated.status = .completed
                    updated.completedAt = .now
                    updated.updatedAt = .now
                    try await store.updateReminder(updated, learningProfile: learningProfile)
                    notificationScheduler.cancel(updated)
                    noticeMessage = "提醒已完成。"
                }
                await refresh()
            } catch {
                recordError(error, source: "Reminders", message: "完成提醒失败")
            }
        }
    }

    func snoozeReminder(_ reminder: ReminderCandidate, until dueAt: Date) {
        guard dueAt > .now else { return }
        Task {
            do {
                let previous = reminder
                var updated = reminder
                updated.dueAt = dueAt
                updated.status = .snoozed
                updated.snoozeCount += 1
                updated.updatedAt = .now
                var learningProfile = state.reminderLearningProfile
                learningProfile.record(
                    .snoozed(hour: Calendar.current.component(.hour, from: dueAt)),
                    semanticKey: reminderSemanticKey(updated)
                )
                try await notificationScheduler.schedule(updated)
                do {
                    try await store.updateReminder(updated, learningProfile: learningProfile)
                } catch {
                    try? await notificationScheduler.schedule(previous)
                    throw error
                }
                await refresh()
                noticeMessage = "已稍后到 \(dueAt.formatted(date: .abbreviated, time: .shortened))。"
            } catch {
                recordError(error, source: "Reminders", message: "稍后提醒失败")
            }
        }
    }

    func removeReminder(_ reminder: ReminderCandidate) {
        Task {
            do {
                notificationScheduler.cancel(reminder)
                try await store.removeReminders(ids: Set([reminder.id]))
                await refresh()
            } catch {
                recordError(error, source: "Reminders", message: "移除提醒失败")
            }
        }
    }

    private func handleReminderNotificationAction(id: UUID, action: String) {
        guard let reminder = state.reminders.first(where: { $0.id == id }) else { return }
        switch action {
        case LocalNotificationScheduler.completeActionIdentifier:
            completeReminder(reminder)
        case LocalNotificationScheduler.snoozeHourActionIdentifier:
            snoozeReminder(reminder, until: .now.addingTimeInterval(60 * 60))
        case LocalNotificationScheduler.snoozeTomorrowActionIdentifier:
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now.addingTimeInterval(86_400)
            let dueAt = Calendar.current.date(
                bySettingHour: state.reminderLearningProfile.preferredHour,
                minute: 0,
                second: 0,
                of: tomorrow
            ) ?? tomorrow
            snoozeReminder(reminder, until: dueAt)
        default:
            break
        }
    }

    private func reminderSemanticKey(_ reminder: ReminderCandidate) -> String {
        if !reminder.semanticKey.isEmpty { return reminder.semanticKey }
        return String(
            reminder.title
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
        )
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
                recordError(error, source: "Reminders", message: "批量忽略提醒失败")
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
                recordError(error, source: "Privacy", message: "保存隐私设置失败")
            }
        }
    }

    func updateDailySummarySettings(_ settings: DailySummarySettings) {
        state.dailySummarySettings = settings
        Task {
            do {
                var persisted = settings
                if settings.isEnabled && settings.notifyWhenReady == true {
                    let granted = try await notificationScheduler.requestAuthorization()
                    guard granted else {
                        persisted.notifyWhenReady = false
                        try await store.updateDailySummarySettings(persisted)
                        await refresh()
                        noticeMessage = "系统通知未授权；自动总结仍会执行，但完成后不会推送。"
                        return
                    }
                } else {
                    notificationScheduler.cancelDailyReview()
                }
                try await store.updateDailySummarySettings(persisted)
                await refresh()
                if settings.isEnabled {
                    noticeMessage = "每日总结已开启：将在每天 \(dailySummaryTimeText(settings)) 汇总前一天记录。"
                } else {
                    noticeMessage = "每日总结已关闭；已有总结会继续保留，直到你手动删除。"
                }
            } catch {
                recordError(error, source: "DailySummary", message: "保存每日总结设置失败")
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
                recordError(error, source: "DailySummary", message: "删除每日总结失败")
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
                recordError(error, source: "Model", message: "保存模型配置失败")
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
                recordError(error, source: "Model", message: "保存模型连接失败")
            }
        }
    }

    private enum DailySummaryReason {
        case scheduled
        case manual
    }

    private func generateDailySummary(for day: Date, reason: DailySummaryReason) {
        if isGeneratingDailySummary {
            guard !pendingDailySummaries.contains(where: { Calendar.current.isDate($0.day, inSameDayAs: day) }) else { return }
            pendingDailySummaries.append((day, reason))
            pendingDailySummaries.sort { $0.day < $1.day }
            return
        }
        isGeneratingDailySummary = true
        isThinking = true
        let captures = state.captures
        let previousSummaries = state.dailySummaries
        let responder = dailySummaryResponder()
        Task {
            defer {
                isGeneratingDailySummary = false
                isThinking = false
                processNextDailySummary()
            }
            do {
                let generation = try await dailySummaryGenerator.generate(
                    day: day,
                    from: captures,
                    previousSummaries: previousSummaries,
                    existingEpisodes: state.episodes,
                    previousProjects: state.projects,
                    existingMemories: state.userMemories,
                    previousInsights: state.insights,
                    feedback: state.insightFeedback,
                    existingRoutines: state.learnedRoutines,
                    responder: responder
                )
                let summary = DailySummary(
                    day: day,
                    content: generation.content,
                    sourceCaptureIDs: generation.sourceCaptureIDs,
                    todos: generation.todos,
                    generationKind: generation.generationKind,
                    briefing: generation.briefing
                )
                try await store.commitDailySummary(summary, consolidation: generation.consolidation)
                await refresh()
                if state.dailySummarySettings.notifyWhenReady == true {
                    do {
                        try await notificationScheduler.deliverDailyBriefing(summary)
                    } catch {
                        recordDiagnostic(.warning, source: "DailySummary", message: "个人简报已保存，但系统通知投递失败", metadata: ["error": recallSafeErrorCode(error)])
                    }
                }
                if !summary.todos.isEmpty {
                    discoverReminders(force: false, announce: false)
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
            }
        }
    }

    private func processNextDailySummary() {
        guard !isGeneratingDailySummary, !pendingDailySummaries.isEmpty else { return }
        let next = pendingDailySummaries.removeFirst()
        generateDailySummary(for: next.day, reason: next.reason)
    }

    func reviewInsight(_ insight: PersonalInsight, rating: InsightFeedbackRating) {
        Task {
            do {
                try await store.reviewInsight(id: insight.id, rating: rating)
                await refresh()
                noticeMessage = rating == .inaccurate || rating == .dismissed
                    ? "已记住这类判断不适合你，后续会降低或停止推送。"
                    : "反馈已记录，Recall 会据此调整后续判断。"
            } catch {
                recordError(error, source: "Insights", message: "保存洞察反馈失败")
            }
        }
    }

    func reviewUserMemory(_ memory: UserMemory, status: MemoryReviewStatus) {
        Task {
            do {
                try await store.reviewUserMemory(id: memory.id, status: status)
                await refresh()
                noticeMessage = status == .confirmed ? "这条认识已加入长期用户档案。" : "这条认识已否定，不会用于后续个性化。"
            } catch {
                recordError(error, source: "Memory", message: "保存用户记忆反馈失败")
            }
        }
    }

    func updateLearnedRoutine(_ routine: LearnedRoutine, status: LearnedRoutineStatus) {
        Task {
            do {
                try await store.updateRoutine(id: routine.id, status: status)
                await refresh()
                noticeMessage = status == .enabled
                    ? "已启用该个人规则；它只会提出建议或提醒候选，不会自动执行外部动作。"
                    : "已忽略该个人规则。"
            } catch {
                recordError(error, source: "Routines", message: "更新个人规则失败")
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
        let calendar = Calendar.current
        let existingDays = state.dailySummaries.map { calendar.startOfDay(for: $0.day) }
        let capturedDays = Set(state.captures
            .filter { $0.eventTemplate != .dailyReview }
            .map { calendar.startOfDay(for: $0.createdAt) })
        let missingDays = (1...14).compactMap { offset -> Date? in
            guard let candidate = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let day = calendar.startOfDay(for: candidate)
            guard capturedDays.contains(day), !existingDays.contains(day) else { return nil }
            return day
        }.sorted()
        guard let first = missingDays.first else { return }
        pendingDailySummaries = missingDays.dropFirst().map { ($0, .scheduled) }
        generateDailySummary(for: first, reason: .scheduled)
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
        let reminders = state.reminders
        Task {
            do {
                notificationScheduler.cancelAll(reminders)
                for capture in captures {
                    try await pipeline.removeCapture(capture)
                }
                try await store.clearReminderData()
                try await store.clearDailySummaries()
                try await store.clearPersonalIntelligence()
                await refresh()
                noticeMessage = "已删除全部本地记忆记录。"
            } catch {
                recordError(error, source: "Data", message: "清除本地数据失败")
            }
        }
    }
}
