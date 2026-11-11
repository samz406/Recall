import Foundation
import RecallKit

extension RecallLayoutPreviews {
    private struct PeriodDeletionFailure: LocalizedError { let errorDescription: String? }
    @MainActor static func verifyPeriodReviewDeletion() async throws {
        let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
        let source = try ManualMatterNote(title: "Atlas 合成验收归档", detail: "验收归档已完成，保留边界检查结果。", status: .completed,
            eventAt: now.addingTimeInterval(-3600), reviewCategory: .work).capture(recordedAt: now.addingTimeInterval(-3600))
        var sample = RecallState(captures: [source])
        let original = try await WeeklyReviewEngine().generate(in: sample, period: ReviewPeriod(start: now.addingTimeInterval(-86_400), end: now),
            template: ReviewTemplate(kind: .work), now: now)
        var sameName = original; sameName.id = UUID()
        var stale = original; stale.id = UUID(); stale.invalidate(at: now)
        sample.weeklyReports = [original, sameName, stale]
        let model = try RecallAppModel(previewState: sample)
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        while model.isBuildingMatters { try await Task.sleep(for: .milliseconds(5)) }
        guard let revision = model.memoryWorkspace?.revision else { throw PeriodDeletionFailure(errorDescription: "周期回顾夹具没有准备好") }
        let before = await model.store.snapshot()
        model.weeklyReportToOpen = stale.id; model.destination = .review(stale.id)
        let first = Task { @MainActor in await model.deleteWeeklyReport(stale.id) }
        let repeated = Task { @MainActor in await model.deleteWeeklyReport(stale.id) }
        let results = [await first.value, await repeated.value]
        guard results.filter({ $0 }).count == 1, model.deletingWeeklyReportIDs.isEmpty,
              Set(model.state.weeklyReports.map(\.id)) == [original.id, sameName.id],
              model.weeklyReportToOpen == nil, model.destination == nil,
              model.deletionUndoNotice?.weeklyReports?.first?.id == stale.id,
              model.state.captures == before.captures, model.state.dailySummaries == before.dailySummaries,
              model.memoryWorkspace?.revision == revision, model.tasks.isEmpty,
              !model.isGeneratingWeeklyReview, !model.isGeneratingDailySummary,
              model.weeklyReviewMessage == RecallLocalization.both("回顾已删除，可在最近删除中恢复。", "Review deleted. It can be restored from Recently Deleted.") else {
            throw PeriodDeletionFailure(errorDescription: "删除没有移除准确记录、清空详情、反馈结果，或触发了全局任务")
        }
        let reopened = try FileMemoryStore(storage: model.storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
        let saved = await reopened.snapshot()
        guard !saved.weeklyReports.contains(where: { $0.id == stale.id }), saved.weeklyReports.count == 2 else {
            throw PeriodDeletionFailure(errorDescription: "重启后已删除回顾又出现")
        }
        let undoID = model.deletionUndoNotice?.id
        model.weeklyReportToOpen = original.id; model.destination = .review(original.id)
        let backup = model.storage.stateURL.appendingPathExtension("period-delete-backup")
        try FileManager.default.moveItem(at: model.storage.stateURL, to: backup)
        try FileManager.default.createDirectory(at: model.storage.stateURL, withIntermediateDirectories: false)
        let failed = await model.deleteWeeklyReport(original.id)
        guard !failed, model.deletingWeeklyReportIDs.isEmpty,
              model.state.weeklyReports.contains(where: { $0.id == original.id }), model.weeklyReportToOpen == original.id,
              model.deletionUndoNotice?.id == undoID,
              model.weeklyReviewMessage == RecallLocalization.both("未能删除回顾，请重试。", "Unable to delete this review. Please retry.") else {
            throw PeriodDeletionFailure(errorDescription: "删除失败没有保留原记录/选择或显示重试提示")
        }
        try FileManager.default.removeItem(at: model.storage.stateURL)
        try FileManager.default.moveItem(at: backup, to: model.storage.stateURL)
        guard await model.deleteWeeklyReport(original.id), model.state.weeklyReports.map(\.id) == [sameName.id] else {
            throw PeriodDeletionFailure(errorDescription: "删除失败后无法重试，或误删同名回顾")
        }
        model.weeklyReportToOpen = sameName.id
        guard await model.deleteWeeklyReport(sameName.id), model.state.weeklyReports.isEmpty, model.weeklyReportToOpen == nil else {
            throw PeriodDeletionFailure(errorDescription: "删除最后一份后没有清空列表和详情")
        }
        print("PASS: native period-review deletion removes exact stale/duplicate IDs, clears selection, survives reopen, preserves records, deduplicates clicks and supports write-failure/retry/last-report without global refresh")
    }
}
