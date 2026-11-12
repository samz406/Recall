import Foundation
import RecallKit

@MainActor
extension RecallAppModel {
    func scheduleAutomaticTopicReviews() {
        guard automaticTopicSummaryBudget > 0, (!isPreview || topicReviewResponderOverride != nil), state.memoryKnowledgeSettings.automaticTopicSummaries == true,
              state.memoryKnowledgeSettings.automaticOrganization, state.privacy.cloudUseEnabled,
              topicReviewTask == nil, !isGeneratingDailySummary, !isGeneratingWeeklyReview,
              (topicReviewResponderOverride != nil || dailySummaryResponder() != nil) else { return }
        // Existing history/task entries make cancellation and failure sticky for unchanged inputs.
        let candidates = matterFiles.filter { file in
            let fingerprint = TopicReading.fingerprint(file)
            return topicSummaryAttempts[file.id] != fingerprint
                && state.topicReviews.first(where: { $0.id == file.id })?.inputFingerprint != fingerprint
                && file.events.contains { !$0.quotes.isEmpty }
        }
        guard let file = candidates.first else { return }
        topicSummaryAttempts[file.id] = TopicReading.fingerprint(file)
        automaticTopicSummaryBudget -= 1
        generateTopicReview(file, automatic: true)
    }

    func generateTopicReview(_ file: MatterFile, automatic: Bool = false) {
        guard topicReviewTask == nil, !isGeneratingDailySummary, !isGeneratingWeeklyReview else {
            if !automatic { noticeMessage = RecallLocalization.both("另一份回顾正在更新，请稍后重试。", "Another review is updating. Please try again shortly.") }
            return
        }
        guard let responder = topicReviewResponderOverride ?? dailySummaryResponder() else {
            if !automatic { noticeMessage = RecallLocalization.both("请在设置中连接模型并允许发送脱敏文本；已有记录仍可阅读。", "Connect a model and allow redacted text in Settings. Saved records remain readable.") }
            return
        }
        let taskID = beginTask("主题小结", target: file.title, phase: "准备记录", retry: { [weak self] in
            guard let self, let current = self.matterFiles.first(where: { $0.id == file.id }) else { return }
            self.generateTopicReview(current)
        })
        let keys = Set(([file.title] + file.events.map(\.title)).map(DailyKnowledgeEngine.topicKey))
        let modelStore = store
        topicReviewIsAutomatic = automatic
        generatingTopicID = file.id; topicReviewStatusID = taskID
        topicReviewTask = Task {
            defer {
                topicReviewIsAutomatic = false
                generatingTopicID = nil; topicReviewTask = nil; topicReviewStatusID = nil
                processNextDailySummary()
                if automatic && !Task.isCancelled { scheduleAutomaticTopicReviews() }
            }
            do {
                let current = await modelStore.snapshot()
                let events = DailyKnowledgeEngine().matterFiles(in: current).filter { keys.contains(DailyKnowledgeEngine.topicKey($0.title)) }.flatMap(\.events)
                guard let start = events.map(\.date).min() else { throw WeeklyReviewError.noDailyReviews }
                let span = ReviewPeriod(start: Calendar.current.startOfDay(for: start), end: .now.addingTimeInterval(1))
                let result = try await PeriodReviewFromDaily().generate(in: current, period: span, template: nil, topic: file.title,
                    topicKeys: keys, beforeCall: {
                        if automatic {
                            let latest = await modelStore.snapshot()
                            guard latest.memoryKnowledgeSettings.automaticTopicSummaries == true,
                                  latest.memoryKnowledgeSettings.automaticOrganization else { throw CancellationError() }
                        }
                        try await modelStore.validateDailyDerivedReview(current)
                    }, onProgress: { progress in await self.updateReviewTask(taskID, progress: progress) }, responder: responder).draft
                try Task.checkCancellation()
                guard !result.items.isEmpty else { throw WeeklyReviewError.noEvidence }
                try await modelStore.validateDailyDerivedReview(current)
                var summary = TopicModelReview(topicID: file.id, result: result)
                summary.inputFingerprint = TopicReading.fingerprint(file)
                try await modelStore.commitTopicReview(summary)
                state = await modelStore.snapshot()
                finishTask(taskID, state: .succeeded, message: "主题小结已更新", destination: .topic(file.id))
            } catch {
                let cancelled = ModelCallCancellation.isCancellation(error)
                finishTask(taskID, state: cancelled ? .cancelled : .failed,
                    message: cancelled ? "已停止更新，已有内容可继续阅读" : "更新未完成，已有内容可继续阅读", detail: (error as? ReviewPreparationFailure)?.detail)
                if !cancelled { recordError(error, source: "TopicReview", message: "主题小结未完成，原内容保留") }
            }
        }
    }
    func cancelTopicReview() {
        guard let id = topicReviewStatusID, requestTaskCancellation(id) else { return }
        topicReviewTask?.cancel()
    }
    func undoTopicCompletion(_ topicID: String) {
        Task {
            do {
                let ids = state.matterCorrections.filter { $0.isTopicCompletion && $0.topicID == topicID }.map(\.id)
                for id in ids { try await store.removeMatterCorrection(id: id) }
                state = await store.snapshot(); rebuildMatterFiles()
                noticeMessage = RecallLocalization.both("已撤销完成标记。", "Completion undone.")
            } catch { recordError(error, source: "Memory", message: "撤销完成失败") }
        }
    }
    func undoRemembering(_ sourceID: UUID) {
        Task {
            do {
                try await store.undoRemembering(sourceID: sourceID)
                state = await store.snapshot()
                noticeMessage = RecallLocalization.both("已撤销这次记住的内容。", "This remember operation was undone.")
            } catch { recordError(error, source: "Memory", message: "撤销记忆失败") }
        }
    }
}
