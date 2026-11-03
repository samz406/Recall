import Foundation
import RecallKit

@MainActor
extension RecallAppModel {
    func generateTopicReview(_ file: MatterFile) {
        guard topicReviewTask == nil, !isGeneratingDailySummary, !isGeneratingWeeklyReview else { noticeMessage = "另一份回顾正在生成，完成后可以继续。"; return }
        let taskID = beginTask("主题小结", target: file.title, phase: "准备记录", retry: { [weak self] in
            guard let self, let current = self.matterFiles.first(where: { $0.id == file.id }) else { return }
            self.generateTopicReview(current)
        })
        guard let responder = dailySummaryResponder() else {
            finishTask(taskID, state: .failed, message: ModelReviewError.unavailable.localizedDescription); return
        }
        let ids = Set(file.evidenceIDs)
        let dates = state.captures.filter { ids.contains($0.id) }.map(\.createdAt)
        guard let start = dates.min() else { finishTask(taskID, state: .failed, message: "来源已变化，请更新主题"); return }
        let modelStore = store
        generatingTopicID = file.id
        topicReviewStatusID = taskID
        topicReviewTask = Task {
            defer { generatingTopicID = nil; topicReviewTask = nil; topicReviewStatusID = nil; processNextDailySummary() }
            do {
                let current = await modelStore.snapshot()
                let dailyKey = Set([DailyKnowledgeEngine.topicKey(file.title)])
                guard let daily = DailyKnowledgeEngine().matterFiles(in: current).first(where: { DailyKnowledgeEngine.topicKey($0.title) == DailyKnowledgeEngine.topicKey(file.title) }) else {
                    throw WeeklyReviewError.noDailyReviews
                }
                let prepared = current
                let target = daily
                state = prepared
                let span = ReviewPeriod(start: Calendar.current.startOfDay(for: daily.events.map(\.date).min() ?? start),
                    end: .now.addingTimeInterval(1))
                let result = try await PeriodReviewFromDaily().generate(in: prepared, period: span, template: nil, topic: file.title,
                    topicKeys: dailyKey, beforeCall: { try await modelStore.validateDailyDerivedReview(current) },
                    onProgress: { progress in await self.updateReviewTask(taskID, progress: progress) }, responder: responder).draft
                try Task.checkCancellation()
                guard !result.items.isEmpty else { throw WeeklyReviewError.noEvidence }
                try await modelStore.validateDailyDerivedReview(current)
                try await modelStore.commitTopicReview(TopicModelReview(topicID: target.id, result: result))
                state = await modelStore.snapshot()
                rebuildMatterFiles()
                finishTask(taskID, state: result.coverage.uncertainBlockCount > 0 ? .partial : .succeeded,
                    message: result.coverage.uncertainBlockCount > 0 ? "小结已更新，部分原文暂无法确认" : "主题小结已更新", destination: .topic(target.id))
            } catch {
                let cancelled = ModelCallCancellation.isCancellation(error)
                finishTask(taskID, state: cancelled ? .cancelled : .failed,
                    message: cancelled ? "已取消，原小结保持不变" : error.localizedDescription,
                    detail: (error as? ReviewPreparationFailure)?.detail)
                if !cancelled { recordError(error, source: "TopicReview", message: "主题小结未完成，原内容保留") }
                state = await modelStore.snapshot()
                rebuildMatterFiles()
            }
        }
    }
    func cancelTopicReview() {
        guard let id = topicReviewStatusID, requestTaskCancellation(id) else { return }
        topicReviewTask?.cancel()
    }
}
