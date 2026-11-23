import Foundation
import RecallKit

@MainActor
extension RecallAppModel {
    @discardableResult
    func beginTask(_ kind: String, target: String, phase: String, reviewDay: Date? = nil,
                   replacingDailyReviewID: UUID? = nil, retry: (() -> Void)? = nil) -> UUID {
        var task = RecallTaskStatus(kind: kind, target: target, phase: phase, reviewDay: reviewDay)
        task.replacingDailyReviewID = replacingDailyReviewID
        tasks.removeAll { !$0.isRunning && Date.now.timeIntervalSince($0.startedAt) > 86_400 }
        if let reviewDay {
            tasks.removeAll { previous in
                !previous.isRunning && previous.kind == kind
                    && previous.reviewDay.map { Calendar.current.isDate($0, inSameDayAs: reviewDay) } == true
            }
        }
        if tasks.count >= 20, let index = tasks.lastIndex(where: { !$0.isRunning }) { tasks.remove(at: index) }
        tasks.insert(task, at: 0)
        taskRetryActions = taskRetryActions.filter { id, _ in tasks.contains { $0.id == id } }
        taskRetryActions[task.id] = retry
        return task.id
    }
    func updateTask(_ id: UUID, phase: String, detail: String? = nil) {
        guard let i = tasks.firstIndex(where: { $0.id == id && $0.isRunning }) else { return }
        tasks[i].updateProgress(phase: phase, detail: detail)
    }
    func requestTaskCancellation(_ id: UUID) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        return tasks[index].requestCancellation()
    }
    func updateReviewTask(_ id: UUID, progress: ReviewGenerationProgress) {
        updateTask(id, phase: progress.title, detail: progress.detail)
    }
    func canRetryTask(_ task: RecallTaskStatus) -> Bool {
        guard !task.isRunning, taskRetryActions[task.id] != nil else { return false }
        if let day = task.reviewDay { return state.dailyReview(on: day)?.id == task.replacingDailyReviewID }
        return true
    }
    func retryTask(_ id: UUID) {
        guard !isGeneratingDailySummary, !isGeneratingWeeklyReview, topicReviewTask == nil,
              let task = tasks.first(where: { $0.id == id }), canRetryTask(task),
              let retry = taskRetryActions.removeValue(forKey: id) else { return }
        retry()
    }
    func finishTask(_ id: UUID, state: RecallTaskState, message: String, destination: MemorySearchDestination? = nil, detail: String? = nil) {
        guard let i = tasks.firstIndex(where: { $0.id == id && $0.isRunning }) else { return }
        tasks[i].state = state; tasks[i].phase = message; tasks[i].destination = destination
        tasks[i].detail = detail
        if state == .succeeded || state == .partial { taskRetryActions[id] = nil }
        recordReviewMetric(tasks[i])
    }

    /// Outcome and duration of every daily and period review, for the reliability card in Settings.
    private func recordReviewMetric(_ task: RecallTaskStatus) {
        guard !isPreview else { return }
        let kind: ReviewAttemptMetric.Kind
        switch task.kind { case "每日回顾": kind = .daily; case "周期回顾": kind = .period; default: return }
        let outcome: ReviewAttemptMetric.Outcome
        switch task.state {
        case .succeeded: outcome = .succeeded
        case .partial: outcome = .partial
        case .cancelled: outcome = .cancelled
        case .failed: outcome = .failed
        case .running, .cancelling: return
        }
        let metric = ReviewAttemptMetric(kind: kind, outcome: outcome, milliseconds: Int(Date.now.timeIntervalSince(task.startedAt) * 1000))
        Task {
            do { try await store.recordReviewAttempt(metric); state.reviewAttemptMetrics = await store.snapshot().reviewAttemptMetrics }
            catch { recordError(error, source: "ReviewMetrics", message: "记录回顾统计失败") }
        }
    }
    func mergeTopics(title: String, members: Set<String>) async -> Bool {
        guard members.count >= 2, members.isSubset(of: Set(matterFiles.map(\.id))) else { return false }
        let group = MemoryTopicGroup(title: title, memberIDs: Array(members))
        do { try await store.saveTopicGroup(group); await refresh(); return true }
        catch { recordError(error, source: "Memory", message: "合并主题失败"); return false }
    }
    func undoTopicMerge(_ id: String) {
        Task {
            do { try await store.undoTopicGroup(id); await refresh() }
            catch { recordError(error, source: "Memory", message: "撤销合并失败") }
        }
    }
    func reminder(for title: String, sourceIDs: [UUID], candidateID: UUID? = nil) -> ReminderCandidate? {
        let key = title.filter { $0.isLetter || $0.isNumber }.lowercased()
        return state.reminders.first {
            $0.id == candidateID || ($0.title.filter { $0.isLetter || $0.isNumber }.lowercased() == key
                && !Set($0.sourceCaptureIDs).isDisjoint(with: sourceIDs))
        }
    }
    func prepareReminder(title: String, detail: String, sourceIDs: [UUID], candidateID: UUID? = nil) {
        let live = Set(state.captures.map(\.id))
        guard !sourceIDs.isEmpty, Set(sourceIDs).isSubset(of: live) else { noticeMessage = "来源已变化，请重新生成后再安排。"; return }
        if let existing = reminder(for: title, sourceIDs: sourceIDs, candidateID: candidateID) {
            if [.scheduled, .snoozed, .completed, .cancelled, .dismissed].contains(existing.status) {
                destination = .reminder(existing.id); return
            }
            reminderDraft = existing
        } else {
            reminderDraft = ReminderCandidate(id: candidateID ?? UUID(), title: title, detail: detail,
                sourceCaptureIDs: sourceIDs, confidence: 1, origin: .discovered)
        }
    }
    func openSources(_ ids: [UUID]) {
        if let record = state.captures.first(where: { ids.contains($0.id) }) { sourceToOpen = record }
        else { noticeMessage = "来源已删除或不再可用。" }
    }
}

