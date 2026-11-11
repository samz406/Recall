import Foundation
import RecallKit

enum DailyReviewActionVerification {
    private struct Failure: LocalizedError { let errorDescription: String? }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(errorDescription: message) } }
    static func fixture() throws -> RecallState {
        let date = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970) - 86_400)
        let source = CaptureRecord(eventTemplate: .manualMoment, createdAt: date, sourceAppName: "Synthetic", contentHash: "daily-action-fixture",
            ocrText: "[聊天·自己] Atlas 轮值表由我负责，下一班日期仍待落实。", textOrigin: .screenOCR)
        let id = UUID()
        let knowledge = DailyItemKnowledge(topic: "Atlas 轮值", kind: .matter, status: "pending", ownedByUser: true, quotes: [source.ocrText])
        let item = DailySummaryItem(section: .actions, title: "Atlas 轮值表", detail: "下一班日期仍待落实。", evidenceIDs: [source.id], actionCandidateID: id, knowledge: knowledge)
        // Old archives may have a todo without source IDs. The item still has valid evidence.
        let todo = DailySummaryTodo(id: id, title: item.title, detail: item.detail, priority: .normal)
        var summary = DailySummary(day: date, createdAt: date, content: "", sourceCaptureIDs: [source.id], todos: [todo], generationKind: .cloud, items: [])
        summary.modelCoverage = try JSONDecoder().decode(ModelReviewCoverage.self, from: Data(#"{"version":1,"sourceCount":1,"factCount":1,"uncertainBlockCount":0,"createdAt":0}"#.utf8))
        summary.items = [item]
        summary.todos = [todo]
        return RecallState(captures: [source], dailySummaries: [summary])
    }
    static func run() async throws {
        var sample = try fixture(), summary = sample.dailySummaries[0]
        let item = summary.items[0]
        try expect(ReviewContentQuality.presentation(item).title.isEmpty, "夹具应复现旧版显示清理把模型条目清空的路径")
        var empty = item; empty.id = UUID(); empty.title = " \u{200B} "; empty.detail = "\n"
        var marks = empty; marks.id = UUID(); marks.title = "** [9]"
        summary.items += [empty, marks]
        sample.dailySummaries[0] = summary
        let visible = DailyReviewPresentation.items(in: summary, state: sample)
        try expect(visible.count == 1 && visible[0].title == item.title, "模型确认的条目变空，或无正文的条目仍显示状态/操作")
        var legacy = sample
        legacy.reminders = [ReminderCandidate(id: summary.todos[0].id, title: item.title, detail: item.detail, confidence: 1)]
        let legacyCompletion = try DailyReviewActionCompletion(summaryID: summary.id, itemID: item.id, state: legacy)
        try expect(legacyCompletion.reminder.sourceCaptureIDs == item.evidenceIDs, "旧提醒缺失的来源没有补齐，完成后将无法恢复")
        var duplicate = summary.todos[0]; duplicate.id = UUID()
        summary.todos.insert(duplicate, at: 0)
        try expect(DailyReviewPresentation.action(for: item, in: summary)?.id == item.actionCandidateID, "同名待办抢占了精确行动 ID")

        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("daily-review-action-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(sample).write(to: storage.stateURL)
        let store = try FileMemoryStore(storage: storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
        let before = await store.snapshot()
        let completion = try DailyReviewActionCompletion(summaryID: before.dailySummaries[0].id, itemID: item.id, state: before)
        try expect(!completion.reminder.sourceCaptureIDs.isEmpty && !completion.schedulesNextOccurrence, "旧待办的来源没有从回顾条目补齐")
        let first = try await store.completeDailyReviewAction(completion), repeated = try await store.completeDailyReviewAction(completion)
        let done = await store.snapshot()
        try expect(done.dailySummaries.count == before.dailySummaries.count, "完成操作移除了每日回顾")
        try expect(first && !repeated && done.reminders.count == 1 && done.dailySummaries[0].todos[0].status == .completed, "完成未保存或重复执行")
        try expect(done.captures == before.captures && done.dailySummaries[0].items == before.dailySummaries[0].items && done.dailySummaries[0].id == before.dailySummaries[0].id,
            "完成操作删除了回顾或改写了原文")
        try expect(DailyReviewPresentation.items(in: done.dailySummaries[0], state: done).isEmpty, "完成后仍留在接下来要处理")
        let reopened = try FileMemoryStore(storage: storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
        try expect(await reopened.snapshot().dailySummaries[0].todos[0].status == .completed, "重启丢失完成状态")
        try await store.restoreReminderHistory(ids: [completion.reminder.id])
        let restored = await store.snapshot()
        try expect(DailyReviewPresentation.items(in: restored.dailySummaries[0], state: restored).count == 1, "恢复提醒历史后待办无法再次处理")
        let retry = try DailyReviewActionCompletion(summaryID: restored.dailySummaries[0].id, itemID: item.id, state: restored)
        let backup = storage.stateURL.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: storage.stateURL, to: backup)
        try FileManager.default.createDirectory(at: storage.stateURL, withIntermediateDirectories: false)
        do { try await store.completeDailyReviewAction(retry); throw Failure(errorDescription: "磁盘失败被当作完成成功") }
        catch is Failure { throw Failure(errorDescription: "磁盘失败被当作完成成功") } catch {}
        let failed = await store.snapshot()
        try expect(failed.dailySummaries == restored.dailySummaries && failed.reminders == restored.reminders, "写入失败未整体回滚")
        try FileManager.default.removeItem(at: storage.stateURL)
        try FileManager.default.moveItem(at: backup, to: storage.stateURL)
        try await store.completeDailyReviewAction(retry)

        // Repeated reminders advance; only this daily occurrence leaves the pending list.
        var recurring = try fixture()
        let recurringItem = recurring.dailySummaries[0].items[0], action = recurring.dailySummaries[0].todos[0]
        let now = Date.now
        recurring.reminders = [ReminderCandidate(id: action.id, title: action.title, detail: action.detail, dueAt: now.addingTimeInterval(3600),
            sourceCaptureIDs: recurringItem.evidenceIDs, confidence: 1, status: .scheduled, recurrence: .daily)]
        let next = try DailyReviewActionCompletion(summaryID: recurring.dailySummaries[0].id, itemID: recurringItem.id, state: recurring, now: now)
        try expect(next.schedulesNextOccurrence && next.reminder.dueAt! > recurring.reminders[0].dueAt! && next.reminder.closedAt == nil,
            "完成本次行动关闭了重复提醒")
        var unconfirmed = recurring; unconfirmed.reminders[0].status = .proposed
        let unscheduled = try DailyReviewActionCompletion(summaryID: unconfirmed.dailySummaries[0].id, itemID: recurringItem.id, state: unconfirmed, now: now)
        try expect(!unscheduled.schedulesNextOccurrence && unscheduled.reminder.status == .completed, "未启用的重复提醒因标记完成而被自动安排")
        var deleted = recurring; deleted.captures = []
        do { _ = try DailyReviewActionCompletion(summaryID: recurring.dailySummaries[0].id, itemID: recurringItem.id, state: deleted); throw Failure(errorDescription: "来源删除后仍允许完成旧条目") }
        catch is DailyReviewActionError {}
        print("PASS: daily-review actions keep model-approved text, remove empty rows, resolve exact IDs, persist atomically, survive restart, restore, retry failures and preserve recurrence")
    }
}
