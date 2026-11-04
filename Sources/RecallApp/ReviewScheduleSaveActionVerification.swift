import Foundation
import RecallKit

extension RecallLayoutPreviews {
    private enum ScheduleSaveFailure: Error { case failed(String) }
    @MainActor static func verifyReviewScheduleSave() async throws {
        let records = (0..<120).map { i in CaptureRecord(eventTemplate: .manualMoment, sourceAppName: "Synthetic Notes", contentHash: "schedule-\(i)",
            ocrText: "合成归档正文，只用于验证保存计划不触发内容整理。") }
        let model = RecallAppModel(previewState: RecallState(captures: records))
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        while model.isBuildingMatters { try await Task.sleep(for: .milliseconds(5)) }
        let revision = model.memoryWorkspace?.revision
        let before = await model.store.snapshot()
        let plan = ReviewSchedule(template: ReviewTemplate(kind: .personal))
        let started = Date.now
        guard await model.saveReviewSchedule(plan) else { throw ScheduleSaveFailure.failed("页面保存计划失败") }
        let elapsed = Int(Date.now.timeIntervalSince(started) * 1_000)
        guard !model.isBuildingMatters, model.memoryWorkspace?.revision == revision,
              model.savingReviewScheduleIDs.isEmpty, !model.isGeneratingWeeklyReview,
              model.state.captures == before.captures,
              model.state.reviewSchedules.first?.id == plan.id,
              model.diagnosticEntries.allSatisfy({ $0.level != .error }) else {
            throw ScheduleSaveFailure.failed("保存仍触发了记忆整理、生成回顾、通知授权或遗留了保存状态")
        }
        let reopened = try FileMemoryStore(storage: model.storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
        guard await reopened.snapshot().reviewSchedules.first?.id == plan.id else { throw ScheduleSaveFailure.failed("页面显示保存但重启后计划丢失") }

        let stateURL = model.storage.stateURL, backup = stateURL.appendingPathExtension("schedule-backup")
        try FileManager.default.moveItem(at: stateURL, to: backup)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
        var changed = model.state.reviewSchedules[0]; changed.hour = (changed.hour + 1) % 24
        guard await model.saveReviewSchedule(changed) == false, model.savingReviewScheduleIDs.isEmpty,
              model.state.reviewSchedules[0].hour != changed.hour,
              model.weeklyReviewMessage == RecallLocalization.both("计划未能保存，原有计划保持不变，请重试。", "Unable to save the schedule. The previous schedule is unchanged; please retry.") else {
            throw ScheduleSaveFailure.failed("失败没有保留原计划、返回可重试提示或解除忙碌态")
        }
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.moveItem(at: backup, to: stateURL)
        guard await model.saveReviewSchedule(changed), model.state.reviewSchedules[0].hour == changed.hour else {
            throw ScheduleSaveFailure.failed("失败后不能重试保存")
        }
        await model.deleteReviewSchedule(plan.id)
        guard model.state.reviewSchedules.isEmpty, model.memoryWorkspace?.revision == revision else {
            throw ScheduleSaveFailure.failed("删除计划未更新界面或触发全库刷新")
        }
        print("PASS: native schedule-save entry point, visible result, no global refresh, failure/retry and deletion; synthetic save \(elapsed) ms")
    }
}
