import Foundation
import RecallKit

/// Synthetic contracts for repeating series, snoozing, delivery requests, retention and dedupe cost.
enum ReminderTimelineVerification {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(errorDescription: message) } }
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    static func reminder(_ due: Date, _ recurrence: ReminderRecurrence, status: ReminderStatus = .scheduled) -> ReminderCandidate {
        var value = ReminderCandidate(title: "合成每日检查", detail: "", dueAt: due, confidence: 1, status: status, origin: .manual, recurrence: recurrence)
        value.recurrenceAnchor = recurrence == .none ? nil : due
        return value
    }

    static func run() async throws {
        try lateCompletionKeepsSeriesTime()
        try snoozeKeepsSeries()
        try rollForward()
        try monthEnd()
        try requests()
        try await maintenanceAndBatchConfirm()
        try dedupeScales()
        print("PASS: 7 reminder-timeline scenarios (late completion keeps series time, snooze keeps series and repeats, repeating rows roll forward, month-end clamping, exact system requests, history retention/batch confirm, indexed dedupe)")
    }

    static func lateCompletionKeepsSeriesTime() throws {
        let daily = reminder(date(2026, 3, 2, 9), .daily)
        let done = ReminderTimeline.completing(daily, now: date(2026, 3, 2, 15, 20), calendar: calendar)
        try expect(done.dueAt == date(2026, 3, 3, 9) && done.status == .scheduled, "晚完成让每日提醒漂移到完成时刻")
        let weekly = reminder(date(2026, 3, 2, 9), .weekly)
        let weeklyDone = ReminderTimeline.completing(weekly, now: date(2026, 3, 20, 10), calendar: calendar)
        try expect(weeklyDone.dueAt == date(2026, 3, 23, 9), "多周未处理后完成没有回到原星期和时间")
        let once = ReminderTimeline.completing(reminder(date(2026, 3, 2, 9), .none), now: date(2026, 3, 2, 10), calendar: calendar)
        try expect(once.status == .completed && once.closedAt != nil, "单次提醒完成后没有关闭")
    }

    static func snoozeKeepsSeries() throws {
        let daily = reminder(date(2026, 3, 2, 9), .daily)
        let snoozed = ReminderTimeline.snoozing(daily, until: date(2026, 3, 2, 10), now: date(2026, 3, 2, 9, 5))
        try expect(snoozed.dueAt == daily.dueAt && snoozed.snoozedUntil == date(2026, 3, 2, 10) && snoozed.status == .snoozed, "稍后改动了常规时间")
        let requests = ReminderTimeline.requests(for: snoozed, now: date(2026, 3, 2, 9, 5), calendar: calendar)
        try expect(requests.contains { if case .repeating = $0.trigger { true } else { false } }, "稍后期间重复通知被移除，之后不再提醒")
        try expect(requests.contains { $0.trigger == .once(date(2026, 3, 2, 10)) }, "稍后时间没有安排")
        let done = ReminderTimeline.completing(snoozed, now: date(2026, 3, 2, 10, 30), calendar: calendar)
        try expect(done.dueAt == date(2026, 3, 3, 9) && done.snoozedUntil == nil, "稍后后完成导致规律偏移")
        let elapsed = ReminderTimeline.rolledForward(snoozed, now: date(2026, 3, 2, 11), calendar: calendar)
        try expect(elapsed.status == .scheduled && elapsed.snoozedUntil == nil, "过期的稍后没有回到原规律")
        let oneOff = ReminderTimeline.snoozing(reminder(date(2026, 3, 2, 9), .none), until: date(2026, 3, 2, 10))
        let single = ReminderTimeline.requests(for: oneOff, now: date(2026, 3, 2, 9, 30), calendar: calendar)
        try expect(single.count == 1 && single[0].identifier == oneOff.id.uuidString && single[0].trigger == .once(date(2026, 3, 2, 10)), "单次提醒稍后的通知不正确")
    }

    static func rollForward() throws {
        let daily = reminder(date(2026, 3, 2, 9), .daily)
        let today = ReminderTimeline.rolledForward(daily, now: date(2026, 3, 5, 12), calendar: calendar)
        try expect(today.dueAt == date(2026, 3, 5, 9), "重复提醒没有前移到今天这次")
        try expect(ReminderTimeline.isOverdue(today, now: date(2026, 3, 5, 12)), "今天错过的一次不显示逾期")
        let early = ReminderTimeline.rolledForward(daily, now: date(2026, 3, 5, 8), calendar: calendar)
        try expect(early.dueAt == date(2026, 3, 5, 9) && !ReminderTimeline.isOverdue(early, now: date(2026, 3, 5, 8)), "未到今天时间却显示逾期")
        let sameDay = ReminderTimeline.rolledForward(reminder(date(2026, 3, 5, 9), .daily), now: date(2026, 3, 5, 18), calendar: calendar)
        try expect(sameDay.dueAt == date(2026, 3, 5, 9), "当天未处理的一次被静默跳过")
        let once = reminder(date(2026, 3, 2, 9), .none)
        try expect(ReminderTimeline.rolledForward(once, now: date(2026, 3, 5)) == once, "单次提醒被前移")
    }

    static func monthEnd() throws {
        let anchor = date(2026, 1, 31, 9)
        let series = (0..<4).compactMap { ReminderRecurrence.monthly.occurrence($0, anchor: anchor, calendar: calendar) }
        try expect(series == [date(2026, 1, 31, 9), date(2026, 2, 28, 9), date(2026, 3, 31, 9), date(2026, 4, 30, 9)], "月末提醒没有落在短月份最后一天或之后漂移")
        try expect(ReminderRecurrence.monthly.occurrence(after: date(2026, 2, 28, 9), anchor: anchor, calendar: calendar) == date(2026, 3, 31, 9), "短月份之后没有回到原日期")
    }

    static func requests() throws {
        let now = date(2026, 1, 20, 12)
        let monthly = reminder(date(2026, 1, 31, 9), .monthly)
        let dates = ReminderTimeline.requests(for: monthly, now: now, calendar: calendar).compactMap { if case .once(let d) = $0.trigger { d } else { nil } }
        try expect(dates == [date(2026, 1, 31, 9), date(2026, 2, 28, 9), date(2026, 3, 31, 9)], "29–31 日的每月提醒仍使用会跳过短月的系统触发")
        let early = reminder(date(2026, 1, 15, 9), .monthly)
        try expect(ReminderTimeline.requests(for: early, now: now, calendar: calendar).count == 1, "普通每月提醒没有使用单个重复触发")
        let identifiers = Set(ReminderTimeline.identifiers(for: monthly.id))
        try expect(ReminderTimeline.requests(for: monthly, now: now, calendar: calendar).allSatisfy { identifiers.contains($0.identifier) }, "取消时会遗漏部分系统请求")
        try expect(ReminderTimeline.requests(for: reminder(date(2026, 1, 1), .none), now: now).isEmpty, "过去的单次提醒仍被写入系统")
        try expect(ReminderTimeline.requests(for: reminder(date(2026, 3, 1), .daily, status: .planned), now: now).isEmpty, "未安排时间的事项写入了系统通知")
    }

    static func maintenanceAndBatchConfirm() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // The archive stores whole seconds.
        let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
        var state = RecallState()
        var old = ReminderCandidate(title: "很久以前完成的合成事项", detail: "", confidence: 1, status: .completed, createdAt: now.addingTimeInterval(-400 * 86_400), origin: .manual)
        old.closedAt = now.addingTimeInterval(-200 * 86_400)
        var recent = old; recent.id = UUID(); recent.title = "最近完成的合成事项"; recent.closedAt = now.addingTimeInterval(-3 * 86_400)
        var dismissed = old; dismissed.id = UUID(); dismissed.status = .dismissed; dismissed.dismissedUntil = now.addingTimeInterval(-100 * 86_400)
        let series = reminder(now.addingTimeInterval(-3 * 86_400), .daily)
        let proposed = (0..<3).map { ReminderCandidate(title: "合成候选 \($0)", detail: "", confidence: 0.9, origin: .manual) }
        state.reminders = [old, recent, dismissed, series] + proposed
        let storage = try RecallStorage(rootURL: root)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: storage.stateURL)
        let store = try FileMemoryStore(storage: storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
        try expect(try await store.maintainReminders(now: now), "维护没有执行")
        var after = await store.snapshot()
        let ids = Set(after.reminders.map(\.id))
        try expect(!ids.contains(old.id) && !ids.contains(dismissed.id) && ids.contains(recent.id), "过期历史没有在日常维护中清理，或误删近期历史")
        try expect((after.reminders.first { $0.id == series.id }?.dueAt ?? .distantPast) >= Calendar.current.startOfDay(for: now), "重复提醒没有在维护中前移")
        try expect(try await store.maintainReminders(now: now) == false, "没有变化时仍然写入存档")
        try expect(try await store.addAllProposedToToday(now: now) == 3, "全部加入今天数量不正确")
        after = await store.snapshot()
        try expect(after.reminders.filter { $0.status == .planned }.count == 3 && !after.reminders.contains { $0.status == .proposed }, "全部加入今天没有一次完成")
        let reopened = try FileMemoryStore(storage: storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
        let restored = await reopened.snapshot()
        try expect(restored.reminders.first { $0.id == series.id }?.recurrenceAnchor == series.recurrenceAnchor, "重复起点没有持久化")
        try expect(restored.reminders.filter { $0.status == .planned }.allSatisfy { $0.plannedForDay != nil }, "加入今天的日期重启后丢失")
    }

    static func dedupeScales() throws {
        let now = Date.now
        let existing = (0..<1_000).map { i in
            ReminderCandidate(title: "合成项目\(i)号的独立跟进事项", detail: "", confidence: 0.9, status: i % 2 == 0 ? .dismissed : .scheduled,
                              createdAt: now, origin: .discovered)
        }
        let index = ReminderExtractor.BlockIndex(existing)
        let probes = [existing[10], existing[11]] + (0..<200).map { ReminderCandidate(title: "全新的合成任务\($0)", detail: "", confidence: 0.9, origin: .discovered) }
        let started = Date.now
        let indexed = probes.map { index.blocks($0, now: now) }
        let elapsed = Date.now.timeIntervalSince(started)
        // Compare with an unindexed scan through the same public entry point, one reminder at a time.
        let direct = probes.map { probe in existing.contains { ReminderExtractor.BlockIndex([$0]).blocks(probe, now: now) } }
        try expect(indexed == direct, "索引去重结果与逐条比较不一致")
        try expect(indexed[0] && indexed[1] && !indexed[2], "索引去重没有拦住已有事项或误拦新事项")
        try expect(elapsed < 2, "1000 条已有提醒时去重仍然过慢")
    }
}
