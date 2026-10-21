import Foundation
import RecallKit
import SwiftUI
import AppKit

enum ReminderDiscoveryStatus: Equatable {
    case idle
    case searching(eligibleRecordCount: Int, analyzingRecordCount: Int)
    case completed(eligibleRecordCount: Int, analyzedRecordCount: Int, discoveredCount: Int, completedAt: Date)
}

extension Notification.Name {
    static let recallReminderAction = Notification.Name("im.recall.app.reminder-action")
    static let recallOpenReminders = Notification.Name("im.recall.app.open-reminders")
    static let recallOpenWeeklyReview = Notification.Name("im.recall.app.open-weekly-review")
}

@MainActor
final class RecallAppModel: ObservableObject {
    @Published var state = RecallState()
    @Published private(set) var matterFiles: [MatterFile] = []
    @Published private(set) var reviewTopics: [MatterFile] = []
    @Published private(set) var isGeneratingWeeklyReview = false
    @Published var weeklyReviewMessage: String?
    @Published var weeklyReportToOpen: UUID?
    private var weeklyReviewTask: Task<Void, Never>?
    private var weeklyScheduleTimer: Timer?
    private var weeklyWakeObserver: NSObjectProtocol?
    @Published private(set) var isBuildingMatters = false
    @Published private(set) var isOrganizingMemory = false
    @Published var memoryMaintenanceMessage: String?
    private var memoryMaintenanceTimer: Timer?
    private var memoryMaintenanceAfter: Date = .distantPast
    @Published private(set) var matterBuildMessage: String?
    private var matterBuildTask: Task<Void, Never>?
    @Published var isRecording = false
    @Published var isThinking = false
    @Published private(set) var typingMessageID: UUID?
    @Published private(set) var typingMessageContent = ""
    private var chatTask: Task<Void, Never>?
    private var chatRequestID = UUID()
    @Published var noticeMessage: String?
    @Published private(set) var deletionUndoNotice: RecentlyDeletedMemory?
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
    private var recentlyDeletedTimer: Timer?
    private var recentlyDeletedRetryAfter: Date?
    private var isPurgingRecentlyDeleted = false
    private var isGeneratingDailySummary = false
    private var pendingDailySummaries: [(day: Date, reason: DailySummaryReason)] = []
    private let diagnosticLog: RecallDiagnosticLogStore
    private var reminderActionObserver: NSObjectProtocol?
    private var appActiveObserver: NSObjectProtocol?

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
            appActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.cleanupExpiredRecentlyDeleted()
                    await self?.refresh()
                }
            }
            weeklyWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refresh() }
            }
            Task {
                await cleanupExpiredRecentlyDeleted()
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
        await maintainMemory()
        state = await store.snapshot()
        rebuildMatterFiles()
        updateEnterKeyRecorder()
        await refreshReminderDeliveryStates()
        armDailySummaryTimer()
        armRecentlyDeletedTimer()
        generateMissedDailySummaryIfNeeded()
        armWeeklySchedules()
        runDueWeeklySchedule()
        if memoryMaintenanceTimer == nil {
            memoryMaintenanceTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refresh() }
            }
        }
    }

    func maintainMemory(force: Bool = false) async {
        guard !isOrganizingMemory, force || Date.now >= memoryMaintenanceAfter else { return }
        isOrganizingMemory = true
        defer { isOrganizingMemory = false }
        memoryMaintenanceAfter = Date.now.addingTimeInterval(5 * 60)
        do {
            let before = await store.snapshot()
            try await store.organizeMemory(force: force)
            let paths = try await store.prune()
            var cleaned: [String] = []
            var failed = false
            for path in paths {
                do { try storage.deleteScreenshot(relativePath: path); cleaned.append(path) }
                catch { failed = true; recordError(error, source: "Memory", message: "到期截图清理失败，将重试") }
            }
            if !cleaned.isEmpty { try await store.finishScreenshotCleanup(paths: cleaned) }
            let after = await store.snapshot()
            let remaining = Set(after.reminders.map(\.id))
            for reminder in before.reminders where !remaining.contains(reminder.id) { notificationScheduler.cancel(reminder) }
            if failed { memoryMaintenanceAfter = Date.now.addingTimeInterval(60) }
            if force { memoryMaintenanceMessage = "已整理有效事实、约定和历史经验，重复来源已合并。" }
            state = after
        } catch {
            memoryMaintenanceAfter = Date.now.addingTimeInterval(60)
            recordError(error, source: "Memory", message: "记忆整理或到期清理失败，将重试")
            memoryMaintenanceMessage = "暂未完成整理，稍后会自动重试。"
        }
    }

    func organizeMemoryNow() {
        Task { await maintainMemory(force: true); await refresh() }
    }

    func updateMemorySettings(_ settings: MemoryKnowledgeSettings) {
        Task {
            do { try await store.updateMemoryKnowledgeSettings(settings); await refresh() }
            catch { recordError(error, source: "Memory", message: "保存记忆设置失败") }
        }
    }

    func saveMemoryAgreement(content: String, scope: MemoryScope, replacing: MemoryClaim? = nil) async -> Bool {
        do {
            if let replacing { try await store.correctMemory(id: replacing.id, content: content, scope: scope, scopeID: replacing.scopeID) }
            else { _ = try await store.remember(MemoryDirective(content: content, key: "manual:" + UUID().uuidString, scope: scope)) }
            await refresh()
            return true
        } catch { recordError(error, source: "Memory", message: "保存记忆约定失败"); return false }
    }

    func retireMemory(_ claim: MemoryClaim) {
        Task {
            do { try await store.retireMemory(id: claim.id); await refresh() }
            catch { recordError(error, source: "Memory", message: "停用记忆失败") }
        }
    }

    func saveMemoryAliases(entity: MemoryEntity, text: String) async -> Bool {
        do {
            try await store.updateMemoryAliases(entityID: entity.id, aliases: text.components(separatedBy: CharacterSet(charactersIn: "，,\n")))
            await refresh(); return true
        } catch { recordError(error, source: "Memory", message: "保存主题别名失败"); return false }
    }

    /// 到期时间触发清理；睡眠或应用不在前台时错过的触发在重新激活时补跑。
    private func armRecentlyDeletedTimer() {
        recentlyDeletedTimer?.invalidate()
        recentlyDeletedTimer = nil
        guard let expiry = state.recentlyDeletedMemories.map(\.expiresAt).min() else { return }
        let now = Date.now
        let nextAttempt = expiry <= now ? max(now, recentlyDeletedRetryAfter ?? now) : expiry
        recentlyDeletedTimer = Timer.scheduledTimer(withTimeInterval: max(1, nextAttempt.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.cleanupExpiredRecentlyDeleted() }
        }
    }

    private func cleanupExpiredRecentlyDeleted() async {
        guard !isPurgingRecentlyDeleted else { return }
        isPurgingRecentlyDeleted = true
        defer {
            isPurgingRecentlyDeleted = false
            armRecentlyDeletedTimer()
        }
        do {
            let count = try await store.purgeExpiredRecentlyDeleted()
            recentlyDeletedRetryAfter = nil
            if count > 0 {
                state = await store.snapshot()
                if let undo = deletionUndoNotice, undo.expiresAt <= .now { deletionUndoNotice = nil }
                recordDiagnostic(.info, source: "MemoryGovernance", message: "到期内容已永久清理", metadata: ["count": String(count)])
            }
        } catch {
            recentlyDeletedRetryAfter = Date.now.addingTimeInterval(15 * 60)
            recordError(error, source: "MemoryGovernance", message: "到期内容清理失败，将自动重试")
        }
    }

    func generateWeeklyReview(period: ReviewPeriod, template: ReviewTemplate, scope: ReviewScope,
                              useModel: Bool, replacing: UUID? = nil, schedule: ReviewSchedule? = nil) {
        guard !isGeneratingWeeklyReview else { return }
        isGeneratingWeeklyReview = true
        weeklyReviewMessage = nil
        let snapshot = state
        let responder = useModel ? dailySummaryResponder() : nil
        let scheduledTrigger = schedule?.effectiveTrigger(at: .now)
        weeklyReviewTask = Task {
            defer { isGeneratingWeeklyReview = false; weeklyReviewTask = nil }
            do {
                let job = Task.detached(priority: .userInitiated) {
                    try await WeeklyReviewEngine().generate(in: snapshot, period: period, template: template, scope: scope, responder: responder)
                }
                var report = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
                try Task.checkCancellation()
                if useModel && responder == nil { report.refinementPending = true }
                report.scheduledFor = scheduledTrigger
                let current = await store.snapshot()
                guard current.privacy.cloudUseEnabled == snapshot.privacy.cloudUseEnabled,
                      current.privacy.excludedBundleIdentifiers == snapshot.privacy.excludedBundleIdentifiers else { throw WeeklyReviewError.changedSources }
                let saved = try await store.commitWeeklyReport(report, replacing: replacing, schedule: schedule, categories: snapshot.reviewCategories)
                state = await store.snapshot()
                if schedule == nil { weeklyReportToOpen = saved.id }
                weeklyReviewMessage = saved.refinementPending
                    ? "已保存可阅读的版本，未通过模型核对的条目保留原始记录。你可以稍后更新；定时计划最多在一天内重试三次，不影响下一期。"
                    : "回顾已保存。你可以查看依据、调整内容或导出。"
                if saved.refinementPending {
                    recordDiagnostic(.warning, source: "WeeklyReview", message: "模型整理失败或不可用，已保存本地版本", metadata: ["scheduled": schedule == nil ? "false" : "true"])
                }
                if let schedule, schedule.notifyWhenReady, !saved.refinementPending {
                    do { try await notificationScheduler.deliverWeeklyReview(saved) }
                    catch { recordError(error, source: "WeeklyReview", message: "一周回顾已保存，通知投递失败") }
                }
            } catch is CancellationError {
                weeklyReviewMessage = "已取消生成，已有回顾保持不变。"
            } catch {
                weeklyReviewMessage = error.localizedDescription
                recordError(error, source: "WeeklyReview", message: "一周回顾生成失败")
                if let schedule {
                    let skip = (error as? WeeklyReviewError) == .noEvidence || (error as? WeeklyReviewError) == .noWorkScope || (error as? WeeklyReviewError) == .invalidPeriod
                    do { try await store.deferReviewSchedule(schedule, noEvidence: skip); state = await store.snapshot() }
                    catch { recordError(error, source: "WeeklyReview", message: "保存回顾重试状态失败") }
                }
            }
        }
    }

    func weeklyMarkdownForExport(_ id: UUID) async -> String? {
        let snapshot = await store.snapshot()
        guard let report = snapshot.weeklyReports.first(where: { $0.id == id && $0.isReadable }),
              WeeklyReviewEngine.sourcesUnchanged(report, in: snapshot) else { return nil }
        return report.markdown
    }

    func logWeeklyExportFailure(_ error: Error) { recordError(error, source: "WeeklyReview", message: "导出一周回顾失败") }

    func cancelWeeklyReview() { weeklyReviewTask?.cancel() }

    func saveReviewTemplate(_ template: ReviewTemplate) async -> Bool {
        do { try await store.saveReviewTemplate(template); state = await store.snapshot(); return true }
        catch { recordError(error, source: "WeeklyReview", message: "保存回顾模板失败"); return false }
    }

    func deleteReviewTemplate(_ id: String) async {
        do { try await store.deleteReviewTemplate(id: id); state = await store.snapshot() }
        catch { recordError(error, source: "WeeklyReview", message: "删除回顾模板失败") }
    }

    func setReviewCategory(topicID: String, category: ReviewCategory) async {
        do { try await store.saveReviewCategory(topicID: topicID, category: category); await refresh() }
        catch { recordError(error, source: "WeeklyReview", message: "保存主题分类失败") }
    }

    func saveReviewSchedule(_ value: ReviewSchedule) async -> Bool {
        var schedule = value
        if schedule.notifyWhenReady {
            do {
                let granted = try await notificationScheduler.requestAuthorization()
                if !granted {
                    schedule.notifyWhenReady = false
                    weeklyReviewMessage = "自动生成会照常执行；系统通知未授权。"
                }
            } catch {
                schedule.notifyWhenReady = false
                recordError(error, source: "WeeklyReview", message: "回顾通知授权失败")
            }
        }
        do { try await store.saveReviewSchedule(schedule); await refresh(); return true }
        catch { recordError(error, source: "WeeklyReview", message: "保存回顾计划失败"); return false }
    }

    func deleteReviewSchedule(_ id: UUID) async {
        do { try await store.deleteReviewSchedule(id: id); state = await store.snapshot() }
        catch { recordError(error, source: "WeeklyReview", message: "删除回顾计划失败") }
    }

    func editWeeklyReport(_ id: UUID, markdown: String?) async -> Bool {
        do { try await store.editWeeklyReport(id: id, markdown: markdown); state = await store.snapshot(); return true }
        catch { recordError(error, source: "WeeklyReview", message: "保存回顾修改失败"); return false }
    }

    func deleteWeeklyReport(_ id: UUID) async {
        do {
            deletionUndoNotice = try await store.deleteWeeklyReport(id: id)
            await refresh()
        } catch { recordError(error, source: "WeeklyReview", message: "删除一周回顾失败") }
    }

    private func armWeeklySchedules() {
        guard weeklyScheduleTimer == nil else { return }
        weeklyScheduleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.runDueWeeklySchedule() }
        }
    }

    private func runDueWeeklySchedule() {
        guard !isGeneratingWeeklyReview,
              let work = WeeklyReviewWork.next(in: state, at: .now, modelAvailable: dailySummaryResponder() != nil) else { return }
        switch work {
        case .generate(let schedule, let trigger):
            // Coalesce missed runs using the scheduled cutoff, never app reopen time.
            let report = schedule.lastReportID.flatMap { id in state.weeklyReports.first { $0.id == id && $0.scheduledFor == trigger } }
            if report?.editedMarkdown != nil {
                Task {
                    do { try await store.deferReviewSchedule(schedule, noEvidence: true); state = await store.snapshot() }
                    catch { recordError(error, source: "WeeklyReview", message: "更新已编辑回顾的计划状态失败") }
                }
                return
            }
            generateWeeklyReview(period: schedule.period(at: trigger), template: schedule.template, scope: schedule.scope,
                useModel: schedule.useModel, replacing: report?.id, schedule: schedule)
        case .refine(let report, let schedule):
            refineWeeklyReport(report, schedule: schedule)
        }
    }

    private func refineWeeklyReport(_ original: WeeklyReport, schedule: ReviewSchedule) {
        guard !isGeneratingWeeklyReview, let responder = dailySummaryResponder() else { return }
        let snapshot = state
        isGeneratingWeeklyReview = true
        weeklyReviewTask = Task {
            defer { isGeneratingWeeklyReview = false; weeklyReviewTask = nil }
            do {
                let job = Task.detached(priority: .utility) {
                    try await WeeklyReviewEngine().refine(original, in: snapshot, responder: responder)
                }
                let report = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
                let current = await store.snapshot()
                guard current.privacy.cloudUseEnabled == snapshot.privacy.cloudUseEnabled,
                      current.privacy.excludedBundleIdentifiers == snapshot.privacy.excludedBundleIdentifiers else { throw WeeklyReviewError.changedSources }
                let saved = try await store.commitWeeklyRefinement(report, expected: original, schedule: schedule, categories: snapshot.reviewCategories)
                state = await store.snapshot()
                if saved.refinementPending {
                    recordDiagnostic(.warning, source: "WeeklyReview", message: "回顾正文核对未通过，保留来源事实", metadata: [:])
                } else if schedule.notifyWhenReady {
                    do { try await notificationScheduler.deliverWeeklyReview(saved) }
                    catch { recordError(error, source: "WeeklyReview", message: "回顾整理完成，通知投递失败") }
                }
            } catch is CancellationError { }
            catch {
                recordError(error, source: "WeeklyReview", message: "回顾正文重试失败")
                do { try await store.deferWeeklyRefinement(original, schedule: schedule); state = await store.snapshot() }
                catch { recordError(error, source: "WeeklyReview", message: "保存正文重试状态失败") }
            }
        }
    }

    func organizeExistingMatters() {
        guard !isBuildingMatters else { return }
        matterBuildMessage = nil
        Task {
            state = await store.snapshot()
            rebuildMatterFiles(announce: true)
        }
    }

    func saveManualMatter(_ note: ManualMatterNote) async -> Bool {
        do {
            try await store.addManualMatter(note)
            await refresh()
            matterBuildMessage = "记录已保存，同名主题的相关内容会串联在一起。"
            return true
        } catch {
            recordError(error, source: "Memory", message: "手动记录事情失败")
            return false
        }
    }

    private func rebuildMatterFiles(announce: Bool = false) {
        matterBuildTask?.cancel()
        let snapshot = state
        isBuildingMatters = true
        matterBuildTask = Task {
            let result = await Task.detached(priority: .utility) {
                (MatterMemoryEngine().files(in: snapshot), WeeklyReviewEngine().topics(in: snapshot))
            }.value
            guard !Task.isCancelled else { return }
            let files = result.0
            matterFiles = files
            reviewTopics = result.1
            isBuildingMatters = false
            if announce {
                if snapshot.captures.isEmpty {
                    matterBuildMessage = "还没有保存的记录。补充一条记录，从这里开始。"
                } else if files.isEmpty {
                    matterBuildMessage = "已检查 \(snapshot.captures.count) 条记录，暂未找到能明确归属的具体主题。你可以补充记录；原始内容仍可在时间线查看。"
                } else {
                    matterBuildMessage = "已检查 \(snapshot.captures.count) 条记录，整理出 \(files.count) 个主题，重复记录已合并。"
                }
            }
        }
    }

    var experienceHint: ExperienceHint? {
        guard state.experienceHintsEnabled else { return nil }
        for file in matterFiles.filter({ $0.latest.status.isOpenMatter && !$0.needsStatusUpdate() }).prefix(3) {
            if let hint = MatterMemoryEngine().experiences(for: file, in: matterFiles)
                .first(where: { !state.dismissedExperienceIDs.contains($0.id) }) { return hint }
        }
        return nil
    }

    func correctMatter(_ correction: MatterCorrection) {
        Task {
            do {
                try await store.saveMatterCorrection(correction)
                if correction.kind == .completed {
                    for reminder in state.reminders where !Set(reminder.sourceCaptureIDs).isDisjoint(with: correction.evidenceIDs) {
                        notificationScheduler.cancel(reminder)
                    }
                }
                await refresh()
                noticeMessage = "已更正；原始记录仍然保留。"
            } catch { recordError(error, source: "Memory", message: "保存纠错失败") }
        }
    }

    func removeMatterCorrection(_ id: UUID) {
        Task {
            do { try await store.removeMatterCorrection(id: id); await refresh() }
            catch { recordError(error, source: "Memory", message: "删除纠错失败") }
        }
    }

    func setExperienceHints(_ enabled: Bool) {
        Task {
            do { try await store.setExperienceHints(enabled: enabled); await refresh() }
            catch { recordError(error, source: "Memory", message: "保存经验提示设置失败") }
        }
    }

    func dismissExperience(_ id: String) {
        Task {
            do { try await store.dismissExperience(id: id); await refresh() }
            catch { recordError(error, source: "Memory", message: "关闭经验提示失败") }
        }
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
            } catch CapturePipelineError.suppressedByUser {
                recordDiagnostic(.info, source: diagnosticSource, message: "内容命中本地忽略规则，已跳过")
            } catch {
                recordDiagnostic(.error, source: diagnosticSource, message: "记录失败", metadata: ["eventTemplate": rule.template.rawValue, "error": recallSafeErrorCode(error)])
            }
        }
    }

    func deletionImpact(for captures: [CaptureRecord]) -> MemoryDeletionImpact {
        MemoryGovernance.impact(of: Set(captures.map(\.id)), in: state)
    }

    func deleteCaptures(
        _ captures: [CaptureRecord],
        reason: MemoryDeletionReason,
        suppressSimilar: Bool
    ) {
        let ids = Set(captures.map(\.id))
        let derivedReminders = state.reminders.filter { reminder in
            reminder.origin != .manual && ids.contains(where: reminder.sourceCaptureIDs.contains)
        }
        Task {
            do {
                guard let transaction = try await store.moveCapturesToRecentlyDeleted(
                    ids: ids,
                    reason: reason,
                    suppressSimilar: suppressSimilar
                ) else { return }
                notificationScheduler.cancelAll(derivedReminders)
                await refresh()
                deletionUndoNotice = transaction
                scheduleDerivedDataRebuild(after: transaction)
            } catch {
                recordError(error, source: "Capture", message: "删除记录失败")
            }
        }
    }

    func deleteCapture(_ capture: CaptureRecord) {
        deleteCaptures([capture], reason: .noLongerNeeded, suppressSimilar: false)
    }

    func deleteDailySummary(_ summary: DailySummary) {
        Task {
            do {
                guard let transaction = try await store.moveDailySummaryToRecentlyDeleted(id: summary.id) else { return }
                await refresh()
                deletionUndoNotice = transaction
            } catch {
                recordError(error, source: "DailySummary", message: "删除每日总结失败")
            }
        }
    }

    func removeSummaryItem(_ item: DailySummaryItem, from summary: DailySummary, reason: MemoryDeletionReason) {
        Task {
            do {
                guard let transaction = try await store.removeDailySummaryItem(
                    summaryID: summary.id,
                    itemID: item.id,
                    reason: reason
                ) else { return }
                await refresh()
                deletionUndoNotice = transaction
            } catch {
                recordError(error, source: "DailySummary", message: "移除总结条目失败")
            }
        }
    }

    func forgetSources(for item: DailySummaryItem, in summary: DailySummary, reason: MemoryDeletionReason, suppressSimilar: Bool) {
        let ids = Set(item.evidenceIDs.isEmpty ? summary.sourceCaptureIDs : item.evidenceIDs)
        let captures = state.captures.filter { ids.contains($0.id) }
        deleteCaptures(captures, reason: reason, suppressSimilar: suppressSimilar)
    }

    func restoreRecentlyDeleted(_ item: RecentlyDeletedMemory) {
        Task {
            do {
                guard let restored = try await store.restoreRecentlyDeleted(id: item.id) else { return }
                await refresh()
                if deletionUndoNotice?.id == item.id { deletionUndoNotice = nil }
                for reminder in restored.reminders where reminder.status == .scheduled || reminder.status == .snoozed {
                    try? await notificationScheduler.schedule(reminder)
                }
                noticeMessage = "已恢复“\(restored.label)”。"
            } catch RecentlyDeletedRestoreError.expired {
                await cleanupExpiredRecentlyDeleted()
                noticeMessage = "已超过 7 天恢复期限，无法恢复。"
            } catch {
                recordError(error, source: "MemoryGovernance", message: "恢复删除内容失败")
            }
        }
    }

    func undoLastDeletion() {
        guard let item = deletionUndoNotice else { return }
        restoreRecentlyDeleted(item)
    }

    func dismissDeletionUndoNotice() {
        deletionUndoNotice = nil
    }

    func permanentlyDelete(_ item: RecentlyDeletedMemory) {
        Task {
            do {
                try await store.purgeRecentlyDeleted(id: item.id)
                await refresh()
                if deletionUndoNotice?.id == item.id { deletionUndoNotice = nil }
                noticeMessage = "已永久删除。"
            } catch {
                recordError(error, source: "MemoryGovernance", message: "永久删除失败")
            }
        }
    }

    func removeSuppressionRule(_ rule: MemorySuppressionRule) {
        Task {
            do {
                try await store.removeSuppressionRule(id: rule.id)
                await refresh()
            } catch {
                recordError(error, source: "MemoryGovernance", message: "删除忽略规则失败")
            }
        }
    }

    private func scheduleDerivedDataRebuild(after transaction: RecentlyDeletedMemory) {
        guard !transaction.affectedDays.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .seconds(10))
            let current = await store.snapshot()
            guard current.recentlyDeletedMemories.contains(where: { $0.id == transaction.id }) else { return }
            for day in transaction.affectedDays.sorted() {
                generateDailySummary(for: day, reason: .rebuildAfterDeletion)
            }
        }
    }

    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let isClear = ChatCommand.parse(question) == .clear
        guard isClear || (!isThinking && typingMessageID == nil) else { return }
        chatTask?.cancel()
        let requestID = UUID()
        chatRequestID = requestID
        typingMessageID = nil
        typingMessageContent = ""
        let userMessage = ConversationMessage(role: .user, content: question)
        let isCommand = ChatCommand.isCommandInput(question)
        if !isCommand { state.messages.append(userMessage) }
        isThinking = true
        chatTask = Task {
            do {
                let answer = try await assistant.ask(question, userMessage: userMessage) { [weak self] in
                    guard let self else { return }
                    let snapshot = await self.store.snapshot()
                    guard !Task.isCancelled, self.chatRequestID == requestID else { return }
                    self.state = snapshot
                }
                let snapshot = await store.snapshot()
                guard !Task.isCancelled, chatRequestID == requestID else { return }
                isThinking = false
                if answer.role == .assistant { typingMessageID = answer.id }
                state = snapshot
                if answer.role == .assistant { await revealAssistantMessage(answer) }
                if chatRequestID == requestID { chatTask = nil }
            } catch is CancellationError {
                guard chatRequestID == requestID else { return }
                isThinking = false
                chatTask = nil
            } catch {
                guard !Task.isCancelled, chatRequestID == requestID else { return }
                isThinking = false
                chatTask = nil
                recordDiagnostic(.error, source: "Chat", message: "问一问请求失败", metadata: ["error": recallSafeErrorCode(error)])
                if isCommand {
                    state.messages.append(ConversationMessage(role: .system, content: "命令执行失败，请重试。"))
                }
            }
        }
    }

    private func revealAssistantMessage(_ message: ConversationMessage) async {
        for chunk in TypewriterTextSequence.chunks(for: message.content) {
            guard !Task.isCancelled, typingMessageID == message.id else { return }
            typingMessageContent += chunk
            try? await Task.sleep(for: .milliseconds(16))
        }
        guard typingMessageID == message.id else { return }
        typingMessageID = nil
        typingMessageContent = ""
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
        let eligibleCaptures = state.correctedForAnalysis().captures.filter {
            participatingTemplates.contains($0.eventTemplate) && $0.createdAt >= oldestRelevantDate
        }
        let checkpoint = state.reminderDiscoveryCheckpoint
        let rescanAll = force || checkpoint.extractorVersion != ReminderExtractor.version
        let changed = rescanAll ? eligibleCaptures : eligibleCaptures.filter {
            checkpoint.processedCaptureHashes[$0.id.uuidString] != $0.contentHash
        }
        // 新证据可能完成/取消旧候选；把未确认候选的来源一并复核，已安排提醒不参与自动改写。
        let pendingSourceIDs = Set(state.reminders.filter { $0.status == .proposed && $0.origin == .discovered }.flatMap(\.sourceCaptureIDs))
        let changedIDs = Set(changed.map(\.id))
        let captures = rescanAll || !changed.isEmpty
            ? eligibleCaptures.filter { rescanAll || changedIDs.contains($0.id) || pendingSourceIDs.contains($0.id) }
            : []
        let revalidatedIDs = rescanAll ? pendingSourceIDs.union(captures.map(\.id)) : Set(captures.map(\.id))
        reminderDiscoveryStatus = .searching(
            eligibleRecordCount: eligibleCaptures.count,
            analyzingRecordCount: captures.count
        )

        Task {
            await Task.yield()
            let extractor = reminderExtractor
            let blockingHistory = state.reminders.filter { $0.status != .proposed }
            let extractedCandidates = await Task.detached(priority: .userInitiated) {
                extractor.candidates(from: captures, existing: blockingHistory, resolutionCaptures: eligibleCaptures)
            }.value
            let completedAt = Date.now
            do {
                let learningProfile = state.reminderLearningProfile
                let availableIDs = Set(state.captures.map(\.id))
                let newCandidates = extractedCandidates.compactMap { candidate -> ReminderCandidate? in
                    guard candidate.sourceCaptureIDs.allSatisfy(availableIDs.contains) else { return nil }
                    var adjusted = candidate
                    adjusted.confidence = min(
                        max(candidate.confidence + learningProfile.confidenceAdjustment(for: reminderSemanticKey(candidate)), 0),
                        0.99
                    )
                    let isExplicit = candidate.detail.hasPrefix("明确提醒") || candidate.detail.hasPrefix("明确待办")
                    return adjusted.confidence >= 0.62 || isExplicit ? adjusted : nil
                }
                let merged = extractor.merging(newCandidates, into: state.reminders, now: completedAt, revalidatedCaptureIDs: revalidatedIDs)
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
                nextCheckpoint.extractorVersion = ReminderExtractor.version
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
        case rebuildAfterDeletion
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
        let analysisState = state.correctedForAnalysis()
        let captures = analysisState.captures
        let previousSummaries = analysisState.dailySummaries
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
                    existingEpisodes: analysisState.episodes,
                    previousProjects: analysisState.projects,
                    existingMemories: analysisState.userMemories,
                    previousInsights: analysisState.insights,
                    feedback: analysisState.insightFeedback,
                    existingRoutines: analysisState.learnedRoutines,
                    existingReminders: analysisState.reminders,
                    responder: responder
                )
                let summary = DailySummary(
                    day: day,
                    content: generation.content,
                    sourceCaptureIDs: generation.sourceCaptureIDs,
                    todos: generation.todos,
                    generationKind: generation.generationKind,
                    briefing: generation.briefing,
                    items: generation.items
                )
                let current = await store.snapshot()
                guard current.matterCorrections.map(\.id) == analysisState.matterCorrections.map(\.id),
                      Set(summary.sourceCaptureIDs).isSubset(of: Set(current.captures.map(\.id))) else {
                    pendingDailySummaries.append((day, reason))
                    return
                }
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
                if reason != .rebuildAfterDeletion {
                    noticeMessage = "已生成 \(day.formatted(date: .abbreviated, time: .omitted)) 的\(mode)。"
                }
                recordDiagnostic(.info, source: "DailySummary", message: "每日总结已生成", metadata: [
                    "reason": reason == .scheduled ? "scheduled" : (reason == .manual ? "manual" : "deletionRebuild"),
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
        let reminders = state.reminders
        Task {
            do {
                notificationScheduler.cancelAll(reminders)
                try await store.clearAllMemoryData()
                await refresh()
                deletionUndoNotice = nil
                noticeMessage = "已删除全部本地记忆记录。"
            } catch {
                recordError(error, source: "Data", message: "清除本地数据失败")
            }
        }
    }
}
