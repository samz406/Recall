import Foundation
import RecallKit

extension RecallLayoutPreviews {
    private enum MemoryReminderFailure: Error { case failed(String) }
    @MainActor private final class NotificationProbe: ReminderCreationScheduling {
        enum Permission { case allowed, denied, unavailable }
        let permission: Permission
        var requests = 0
        var scheduled: [ReminderCandidate] = []
        var cancelled: [UUID] = []
        var queueFails = false
        var onRequest: (@MainActor () async throws -> Void)?
        var onSchedule: (@MainActor () throws -> Void)?
        init(_ permission: Permission) { self.permission = permission }
        func requestAuthorization() async throws -> Bool {
            requests += 1; try await onRequest?()
            if permission == .unavailable { throw ReminderNotificationError.hostApplicationRequired }
            return permission == .allowed
        }
        func schedule(_ reminder: ReminderCandidate) async throws {
            if queueFails { throw ReminderNotificationError.notificationSchedulingFailed }
            scheduled.append(reminder)
            try onSchedule?()
        }
        func cancel(_ reminder: ReminderCandidate) { cancelled.append(reminder.id) }
    }

    @MainActor static func verifyMemoryReminderActions() async throws {
        try await verifyDismissAction()
        for permission in [NotificationProbe.Permission.allowed, .denied, .unavailable] {
            try await verifyManualCreation(permission: permission, queueFails: false)
        }
        try await verifyManualCreation(permission: .allowed, queueFails: true)
        try await verifyManualWriteFailures()
        try verifyReminderCalendar()
        print("PASS: native memory/reminder actions (immediate dismissal, restart/failure, save before permission, denial/unavailable/queue fallback, write rollback, pagination and future calendar)")
    }
    @MainActor private static func verifyDismissAction() async throws {
        let now = Date.now.addingTimeInterval(-60)
        let notes = [ManualMatterNote(title: "Atlas 发布验收", detail: "Atlas 发布的历史验收已完成，保留合成结果。", status: .completed, eventAt: now.addingTimeInterval(-86_400)),
            ManualMatterNote(title: "Atlas 发布接口", detail: "正在推进合成接口。", status: .progressed, eventAt: now),
            ManualMatterNote(title: "Atlas 发布页面", detail: "正在推进合成页面。", status: .progressed, eventAt: now)]
        let records = try notes.map { try $0.capture(recordedAt: now) }
        let model = RecallAppModel(previewState: RecallState(captures: records))
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        while model.isBuildingMatters { try await Task.sleep(for: .milliseconds(5)) }
        guard let hint = model.experienceHint else { throw MemoryReminderFailure.failed("合成主题没有生成历史经验") }
        model.dismissExperience(hint)
        guard model.experienceHint == nil else { throw MemoryReminderFailure.failed("点击后同一经验仍在其他主题显示") }
        try await waitForDismissal(model)
        let reopened = try FileMemoryStore(storage: model.storage, credentials: InMemoryCredentialStore())
        guard hint.isDismissed(using: await reopened.snapshot().dismissedExperienceIDs), model.noticeMessage?.contains("已关闭") == true else {
            throw MemoryReminderFailure.failed("关闭状态没有保存或没有反馈")
        }
        // Make persistence fail, then ensure the optimistic removal returns instead of claiming success.
        let other = ExperienceHint(currentID: hint.currentID, past: MatterEvent(id: UUID(), title: "Nova 合成经验", detail: "独立的合成历史结果。",
            recordedAt: now, status: .completed, evidenceIDs: [UUID()]), matchingTerms: [])
        let backup = try blockStateFile(model.storage)
        model.dismissExperience(other)
        try await waitForDismissal(model)
        guard !other.isDismissed(using: model.state.dismissedExperienceIDs), model.noticeMessage?.contains("未能保存") == true else {
            throw MemoryReminderFailure.failed("失败的关闭操作没有回滚和提示")
        }
        try restoreStateFile(model.storage, backup: backup)
    }
    @MainActor private static func waitForDismissal(_ model: RecallAppModel) async throws {
        for _ in 0..<300 {
            if model.dismissingExperienceIDs.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw MemoryReminderFailure.failed("关闭操作没有结束")
    }
    @MainActor private static func verifyManualCreation(permission: NotificationProbe.Permission, queueFails: Bool) async throws {
        let probe = NotificationProbe(permission); probe.queueFails = queueFails
        let model = RecallAppModel(previewState: RecallState(), reminderCreationScheduler: probe)
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        let store = model.store
        probe.onRequest = {
            let current = await store.snapshot()
            guard current.reminders.count == 1, current.reminders[0].status == .proposed, current.reminders[0].detail == "完整的合成说明" else {
                throw MemoryReminderFailure.failed("通知授权前没有先持久保存手动内容")
            }
        }
        let result = try await model.createReminder(title: "  核对合成验收  ", detail: "完整的合成说明", dueAt: .now.addingTimeInterval(86_400), recurrence: .weekly)
        let reopened = try FileMemoryStore(storage: model.storage, credentials: InMemoryCredentialStore()), persisted = await reopened.snapshot()
        let succeeds = permission == .allowed && !queueFails
        guard persisted.reminders.count == 1, persisted.reminders[0].id == result.reminder.id,
              result.reminder.status == (succeeds ? .scheduled : .proposed), result.reminder.origin == .manual,
              result.reminder.recurrence == .weekly, result.reminder.title == "核对合成验收",
              result.reminder.sourceCaptureIDs.isEmpty, (result.notificationIssue == nil) == succeeds else {
            throw MemoryReminderFailure.failed("手动提醒没有按通知结果保存为待处理或待确认")
        }
        let location = ReminderListLocation(id: result.reminder.id, reminders: model.state.reminders, pageSize: 6)
        guard location?.tab == (succeeds ? 0 : 1), model.noticeMessage == result.message else {
            throw MemoryReminderFailure.failed("保存结果与展示位置或提示不一致")
        }
        let earlier = (0..<13).map { i in ReminderCandidate(title: "较早的合成提醒 \(i)", detail: "", dueAt: .now.addingTimeInterval(Double(i + 1) * 60), confidence: 1, status: .scheduled, origin: .manual) }
        if succeeds {
            let thirdPage = ReminderListLocation(id: result.reminder.id, reminders: earlier + [result.reminder], pageSize: 6)
            guard thirdPage?.tab == 0 && thirdPage?.page == 3 else { throw MemoryReminderFailure.failed("较晚的新建提醒没有定位到第三页") }
        }
    }
    @MainActor private static func verifyManualWriteFailures() async throws {
        let probe = NotificationProbe(.allowed), model = RecallAppModel(previewState: RecallState(), reminderCreationScheduler: probe)
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        let backup = try blockStateFile(model.storage)
        do {
            _ = try await model.createReminder(title: "保留合成输入", detail: "说明", dueAt: .now.addingTimeInterval(86_400), recurrence: .none)
            throw MemoryReminderFailure.failed("保存失败仍关闭了新建流程")
        } catch is ReminderCreationError {} // A failed disk write is returned to the sheet.
        guard probe.requests == 0, model.state.reminders.isEmpty, await model.store.snapshot().reminders.isEmpty else {
            throw MemoryReminderFailure.failed("保存失败却请求通知或留下幽灵提醒")
        }
        try restoreStateFile(model.storage, backup: backup)
        var secondBackup: URL?
        probe.onSchedule = { secondBackup = try blockStateFile(model.storage) }
        let result = try await model.createReminder(title: "保留合成输入", detail: "说明", dueAt: .now.addingTimeInterval(86_400), recurrence: .none)
        guard result.reminder.status == .proposed, result.notificationIssue != nil, probe.cancelled == [result.reminder.id],
              model.state.reminders.count == 1, let secondBackup else { throw MemoryReminderFailure.failed("排队后保存失败没有撤回通知并保留草稿") }
        try restoreStateFile(model.storage, backup: secondBackup)
        let reopened = try FileMemoryStore(storage: model.storage, credentials: InMemoryCredentialStore())
        guard await reopened.snapshot().reminders.first?.status == .proposed else { throw MemoryReminderFailure.failed("通知失败的草稿重启后丢失") }
    }
    @MainActor private static func verifyReminderCalendar() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 16, minute: 45))!
        let nextYear = calendar.date(from: DateComponents(year: 2027, month: 1, day: 5))!
        let moved = ReminderDateTimeField.moving(date, to: nextYear, calendar: calendar)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: moved)
        guard parts.year == 2027, parts.month == 1, parts.day == 5, parts.hour == 16, parts.minute == 45 else {
            throw MemoryReminderFailure.failed("更换提醒日期改变了时刻或年份")
        }
        let reminder = TimelineCalendarPopover(selectedDay: .now, earliestDay: .now, latestDay: nil) { _ in }
        let timeline = TimelineCalendarPopover(selectedDay: .now) { _ in }
        guard reminder.latestDay == nil, reminder.earliestDay != nil, timeline.latestDay != nil else { throw MemoryReminderFailure.failed("未来提醒日期仍被时间线的今天上限限制") }
    }
    private static func blockStateFile(_ storage: RecallStorage) throws -> URL {
        let backup = storage.stateURL.appendingPathExtension("action-backup")
        try FileManager.default.moveItem(at: storage.stateURL, to: backup)
        try FileManager.default.createDirectory(at: storage.stateURL, withIntermediateDirectories: false)
        return backup
    }
    private static func restoreStateFile(_ storage: RecallStorage, backup: URL) throws {
        try FileManager.default.removeItem(at: storage.stateURL)
        try FileManager.default.moveItem(at: backup, to: storage.stateURL)
    }
}
