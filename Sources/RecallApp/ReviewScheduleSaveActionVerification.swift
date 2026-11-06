import Foundation
import RecallKit

extension RecallLayoutPreviews {
    private enum ScheduleSaveFailure: Error { case failed(String) }
    @MainActor static func verifyReviewScheduleSave() async throws {
        let records = (0..<120).map { i in CaptureRecord(eventTemplate: .manualMoment, sourceAppName: "Synthetic Notes", contentHash: "schedule-\(i)",
            ocrText: "合成归档正文，只用于验证保存计划不触发内容整理。") }
        let model = try RecallAppModel(previewState: RecallState(captures: records))
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        while model.isBuildingMatters { try await Task.sleep(for: .milliseconds(5)) }
        let revision = model.memoryWorkspace?.revision
        // Compare the displayed snapshot to itself. The store's ISO-8601 decoder rounds
        // synthetic subsecond dates; metadata saves must not replace the UI's capture array.
        let before = model.state
        let plan = ReviewSchedule(template: ReviewTemplate(kind: .personal))
        let started = Date.now
        guard await model.saveReviewSchedule(plan) else { throw ScheduleSaveFailure.failed("页面保存计划失败") }
        let elapsed = Int(Date.now.timeIntervalSince(started) * 1_000)
        guard !model.isBuildingMatters, model.memoryWorkspace?.revision == revision else { throw ScheduleSaveFailure.failed("保存重新整理了记忆投影") }
        guard model.savingReviewScheduleIDs.isEmpty, !model.isGeneratingWeeklyReview else { throw ScheduleSaveFailure.failed("保存状态未解除或立即生成了回顾") }
        guard model.state.captures == before.captures else { throw ScheduleSaveFailure.failed("元数据保存替换了界面上的原始记录") }
        guard model.state.reviewSchedules.first?.id == plan.id else { throw ScheduleSaveFailure.failed("保存成功后页面没有计划") }
        guard model.diagnosticEntries.allSatisfy({ $0.level != .error }) else { throw ScheduleSaveFailure.failed("未选通知仍请求权限或保存过程报错") }
        let reopened = try FileMemoryStore(storage: model.storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
        guard await reopened.snapshot().reviewSchedules.first?.id == plan.id else { throw ScheduleSaveFailure.failed("页面显示保存但重启后计划丢失") }

        let scheduleURL = model.storage.reviewSchedulesURL
        let backup = scheduleURL.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: scheduleURL, to: backup)
        try FileManager.default.createDirectory(at: scheduleURL, withIntermediateDirectories: false)
        var changed = model.state.reviewSchedules[0]; changed.hour = (changed.hour + 1) % 24
        guard await model.saveReviewSchedule(changed) == false, model.savingReviewScheduleIDs.isEmpty,
              model.state.reviewSchedules[0].hour != changed.hour,
              model.weeklyReviewMessage == RecallLocalization.both("计划未能保存，原有计划保持不变，请重试。", "Unable to save the schedule. The previous schedule is unchanged; please retry.") else {
            throw ScheduleSaveFailure.failed("失败没有保留原计划、返回可重试提示或解除忙碌态")
        }
        try FileManager.default.removeItem(at: scheduleURL)
        try FileManager.default.moveItem(at: backup, to: scheduleURL)
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

