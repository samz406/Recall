import Foundation
import RecallKit

extension RecallLayoutPreviews {
    private struct TopicCompletionFailure: LocalizedError { let errorDescription: String? }

    @MainActor static func verifyTopicCompletionAction() async throws {
        let date = Date.now.addingTimeInterval(-3600)
        let note = try ManualMatterNote(title: "Atlas 合成页面验收", detail: "合成验收仍在推进。", status: .progressed, eventAt: date).capture(recordedAt: date)
        let model = try RecallAppModel(previewState: RecallState(captures: [note]))
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        while model.isBuildingMatters { try await Task.sleep(for: .milliseconds(5)) }
        guard let file = model.matterFiles.first else { throw TopicCompletionFailure(errorDescription: "未建立主题按钮夹具") }
        let before = await model.store.snapshot()
        let first = Task { @MainActor in await model.completeMatter(file) }
        let second = Task { @MainActor in await model.completeMatter(file) }
        let results = [await first.value, await second.value]
        guard results.filter({ $0 }).count == 1, model.completingMatterIDs.isEmpty,
              model.matterFiles.first?.latest.status == .completed,
              model.state.matterCorrections.count == 1,
              model.state.captures == before.captures,
              model.noticeMessage == RecallLocalization.both("已标记完成，可在“已完成”中查看。", "Marked complete. Find it in Completed."),
              model.tasks.isEmpty, !model.isGeneratingDailySummary, !model.isGeneratingWeeklyReview else {
            throw TopicCompletionFailure(errorDescription: "按钮未更新列表、重复写入、缺少反馈或启动了全局任务")
        }
        let reopened = try FileMemoryStore(storage: model.storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
        guard MatterMemoryEngine().files(in: await reopened.snapshot()).first?.latest.status == .completed else {
            throw TopicCompletionFailure(errorDescription: "完成仅显示在界面上，重启后未保存")
        }
        // Undo through the same user-facing entry point before exercising write failure/retry.
        model.removeMatterCorrection(model.state.matterCorrections[0].id)
        for _ in 0..<300 {
            if model.matterFiles.first?.latest.status == .progressed && !model.isBuildingMatters { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let restored = model.matterFiles.first, restored.latest.status == .progressed else {
            throw TopicCompletionFailure(errorDescription: "更正记录入口未撤销完成")
        }
        let backup = model.storage.stateURL.appendingPathExtension("topic-action-backup")
        try FileManager.default.moveItem(at: model.storage.stateURL, to: backup)
        try FileManager.default.createDirectory(at: model.storage.stateURL, withIntermediateDirectories: false)
        let failed = await model.completeMatter(restored)
        let failedState = await model.store.snapshot()
        guard !failed, model.completingMatterIDs.isEmpty, model.state.matterCorrections.isEmpty,
              failedState.matterCorrections.isEmpty, model.matterFiles.first?.latest.status == .progressed,
              model.noticeMessage == RecallLocalization.both("未能保存完成状态，请重试。", "Unable to save completion. Please retry.") else {
            throw TopicCompletionFailure(errorDescription: "磁盘失败没有保留原状态、解除忙碌态或显示失败反馈")
        }
        try FileManager.default.removeItem(at: model.storage.stateURL)
        try FileManager.default.moveItem(at: backup, to: model.storage.stateURL)
        guard await model.completeMatter(restored), model.matterFiles.first?.latest.status == .completed else {
            throw TopicCompletionFailure(errorDescription: "保存失败后无法重试完成")
        }
        print("PASS: native topic-completion action updates filters, coalesces repeat clicks, preserves sources, survives restart and supports undo/write-failure/retry without global refresh")
    }
}
