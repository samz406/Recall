import Foundation
import Combine
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
        var buildStarts = 0
        let observation = model.$isBuildingMatters.dropFirst().sink { if $0 { buildStarts += 1 } }
        defer { observation.cancel() }
        let first = Task { @MainActor in await model.completeMatter(file) }
        let second = Task { @MainActor in await model.completeMatter(file) }
        let results = [await first.value, await second.value]
        guard results.filter({ $0 }).count == 1, model.completingMatterIDs.isEmpty,
              model.matterFiles.first?.latest.status == .completed,
              model.state.matterCorrections.count == 1,
              model.state.captures == before.captures,
              model.noticeMessage == RecallLocalization.both("已标记完成，可在“已完成”中查看。", "Marked complete. Find it in Completed."),
              buildStarts == 0, !model.isBuildingMatters,
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
        try await verifyLargeTopicCompletionSave()
    }

    @MainActor private static func verifyLargeTopicCompletionSave() async throws {
        // Multiple topics with distinct evidence and substantial saved text. A single-note
        // fixture cannot detect waiting for the entire archive projection after a small write.
        let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970) - 3600)
        let records = try (0..<6_351).map { i in
            let date = now.addingTimeInterval(-Double(i))
            return try ManualMatterNote(title: "Atlas 合成验收 \(i % 127)",
                detail: "第 \(i) 条合成进展。" + String(repeating: "保留完整验收过程与边界样本，等待继续核对。", count: 12),
                status: .progressed, eventAt: date).capture(recordedAt: date)
        }
        let model = try RecallAppModel(previewState: RecallState(captures: records))
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        for _ in 0..<6_000 {
            if !model.isBuildingMatters { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard !model.isBuildingMatters, let file = model.matterFiles.first, let workspace = model.memoryWorkspace,
              model.matterFiles.count == 127 else { throw TopicCompletionFailure(errorDescription: "大型主题保存夹具未准备好") }
        let before = model.state, timelineBuilds = model.timelineWorkspace.indexBuildCount
        let coverage = workspace.review.coverage(in: .make(.recentSeven))
        let otherFiles = model.matterFiles.filter { $0.id != file.id }
        var buildStarts = 0
        let observation = model.$isBuildingMatters.dropFirst().sink { if $0 { buildStarts += 1 } }
        defer { observation.cancel() }
        let clock = ContinuousClock(), start = clock.now
        let saved = await model.completeMatter(file)
        let elapsed = start.duration(to: clock.now)
        guard saved, elapsed < .seconds(3), buildStarts == 0, !model.isBuildingMatters,
              model.completingMatterIDs.isEmpty, model.memoryWorkspace?.revision != workspace.revision,
              model.memoryWorkspace?.matters.first(where: { $0.id == file.id })?.latest.status == .completed,
              model.matterFiles.first(where: { $0.id == file.id })?.latest.status == .completed,
              model.matterFiles.filter({ $0.id != file.id }) == otherFiles,
              model.state.captures == before.captures, model.timelineWorkspace.indexBuildCount == timelineBuilds,
              model.reviewIndex.coverage(in: .make(.recentSeven)).totalRecords == coverage.totalRecords,
              model.reviewIndex.coverage(in: .make(.recentSeven)).textRecords == coverage.textRecords,
              model.tasks.isEmpty else {
            throw TopicCompletionFailure(errorDescription: "6351 条记录的完成仍等待整库整理、误改其他主题或未结束保存：\(elapsed)")
        }
        let reopened = try FileMemoryStore(storage: model.storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
        let persisted = await reopened.snapshot()
        guard persisted.matterCorrections.count == 1,
              persisted.applyingTopicCompletion(to: file).latest.status == .completed else {
            throw TopicCompletionFailure(errorDescription: "大型档案的完成反馈早于持久化成功")
        }
        // Simulate an older worker finishing after the user save: its sources and indexes
        // stay usable, but its old open status must not overwrite the latest correction.
        let late = workspace.applyingTopicCompletions(in: persisted)
        guard late.matters.first(where: { $0.id == file.id })?.latest.status == .completed,
              late.review.coverage(in: .make(.recentSeven)).totalRecords == coverage.totalRecords else {
            throw TopicCompletionFailure(errorDescription: "迟到的主题投影覆盖了已保存完成状态")
        }
        print("PASS: native topic completion saves 6351 records / 127 topics in \(elapsed), without archive projection or timeline rebuild; durable result, indexes, other topics and late-worker status preserved")
    }
}
