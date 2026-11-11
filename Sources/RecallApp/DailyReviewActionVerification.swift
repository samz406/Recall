import Foundation
import RecallKit

extension RecallLayoutPreviews {
    private struct DailyActionFailure: LocalizedError { let errorDescription: String? }
    @MainActor private final class DailyActionScheduler: ReminderCreationScheduling {
        var requests = 0
        var scheduled: [ReminderCandidate] = []
        var cancelled: [UUID] = []
        func requestAuthorization() async throws -> Bool { requests += 1; return true }
        func schedule(_ reminder: ReminderCandidate) async throws { scheduled.append(reminder) }
        func cancel(_ reminder: ReminderCandidate) { cancelled.append(reminder.id) }
    }
    @MainActor static func verifyDailyReviewAction() async throws {
        let date = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970) - 3600)
        let source = try ManualMatterNote(title: "Atlas 合成验收", detail: "需要复核 Atlas 合成验收。", status: .pending, eventAt: date).capture(recordedAt: date)
        let todo = DailySummaryTodo(title: "复核 Atlas 合成验收", detail: "需要复核 Atlas 合成验收。", sourceCaptureIDs: [source.id], priority: .normal)
        let item = DailySummaryItem(section: .actions, title: todo.title, detail: todo.detail, evidenceIDs: [source.id], actionCandidateID: todo.id,
            knowledge: DailyItemKnowledge(topic: "Atlas 合成验收", kind: .matter, status: "pending", ownedByUser: true, quotes: [source.ocrText]))
        let summary = DailySummary(day: date, createdAt: date, content: "", sourceCaptureIDs: [source.id], todos: [todo], generationKind: .localFallback, items: [item])
        let probe = DailyActionScheduler()
        let model = try RecallAppModel(previewState: RecallState(captures: [source], dailySummaries: [summary]), reminderCreationScheduler: probe)
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        while model.isBuildingMatters { try await Task.sleep(for: .milliseconds(5)) }
        let before = await model.store.snapshot(), revision = model.memoryWorkspace?.revision
        guard let row = before.dailySummaries[0].items.first else { throw DailyActionFailure(errorDescription: "每日回顾行动夹具丢失") }
        let first = Task { @MainActor in await model.completeSummaryAction(row, summary: summary) }
        let repeated = Task { @MainActor in await model.completeSummaryAction(row, summary: summary) }
        let results = [await first.value, await repeated.value]
        guard results.filter({ $0 }).count == 1, model.completingSummaryActionIDs.isEmpty,
              model.state.dailySummaries[0].todos[0].status == .completed,
              DailyReviewPresentation.items(in: model.state.dailySummaries[0], state: model.state).isEmpty,
              model.state.captures == before.captures, model.state.dailySummaries[0].items == before.dailySummaries[0].items,
              model.tasks.isEmpty, model.memoryWorkspace?.revision == revision, !model.isGeneratingDailySummary,
              probe.requests == 0, probe.scheduled.isEmpty, model.dailyReviewActionMessages[summary.id] != nil else {
            throw DailyActionFailure(errorDescription: "标记完成没有更新列表、重复写入、删除原文或触发全局任务/通知权限")
        }
        let reopened = try FileMemoryStore(storage: model.storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
        guard await reopened.snapshot().dailySummaries[0].todos[0].status == .completed else {
            throw DailyActionFailure(errorDescription: "重启后丢失完成状态")
        }
        try await model.store.restoreReminderHistory(ids: [todo.id])
        model.state = await model.store.snapshot()
        let backup = model.storage.stateURL.appendingPathExtension("daily-action-backup")
        try FileManager.default.moveItem(at: model.storage.stateURL, to: backup)
        try FileManager.default.createDirectory(at: model.storage.stateURL, withIntermediateDirectories: false)
        let failed = await model.completeSummaryAction(row, summary: summary)
        guard !failed, model.completingSummaryActionIDs.isEmpty, model.state.dailySummaries[0].todos[0].status == .pending,
              model.dailyReviewActionMessages[summary.id] == RecallLocalization.both("未能保存完成状态，请重试。", "Unable to save completion. Please retry.") else {
            throw DailyActionFailure(errorDescription: "保存失败没有保留待办、解除忙碌态或显示重试提示")
        }
        try FileManager.default.removeItem(at: model.storage.stateURL)
        try FileManager.default.moveItem(at: backup, to: model.storage.stateURL)
        guard await model.completeSummaryAction(row, summary: summary) else { throw DailyActionFailure(errorDescription: "保存失败后无法重试") }
        print("PASS: native daily-review completion updates pending rows, deduplicates clicks, persists across reopen, reports write failure/retry and avoids global maintenance/notification authorization")
    }
}
