import Foundation
import RecallKit

struct TopicActionUndo: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let topicID: String
    let fallbackTitle: String?
    let correctionID: UUID?
    let previousLifecycle: Topic.Lifecycle?
    var restoredCorrections: [MatterCorrection] = []
}

@MainActor
extension RecallAppModel {
    func renameTopic(_ file: MatterFile, to newTitle: String) async -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...80).contains(trimmed.count) else {
            noticeMessage = RecallLocalization.both("主题名称需为 2–80 字。", "Topic name must be 2–80 characters.")
            return false
        }
        do {
            guard try await store.renameTopic(id: file.id, fallbackTitle: file.title, to: trimmed) else {
                noticeMessage = RecallLocalization.both("已存在同名主题，如需合入请使用“合并主题”。", "A topic with that name already exists. Use Merge topics instead.")
                return false
            }
            state = await store.snapshot()
            applyTopicOverlayInPlace()
            noticeMessage = RecallLocalization.both("已重命名为“\(trimmed)”，原名称保留为别名。", "Renamed to “\(trimmed)”. Previous name kept as alias.")
            return true
        } catch {
            recordError(error, source: "Memory", message: "重命名主题失败")
            noticeMessage = RecallLocalization.both("未能保存新名称，请重试。", "Could not rename topic. Please retry.")
            return false
        }
    }

    @discardableResult
    func setTopicLifecycle(id: String, fallbackTitle: String?, lifecycle: Topic.Lifecycle?) async -> Bool {
        let previous = state.topicRegistry.resolvedTopic(id: id, fallbackTitle: fallbackTitle)?.manualLifecycle
        do {
            try await store.setTopicLifecycle(id: id, fallbackTitle: fallbackTitle, lifecycle: lifecycle)
            state = await store.snapshot()
            applyTopicOverlayInPlace()
            let name = fallbackTitle ?? matterFiles.first(where: { state.canonicalTopicID($0.id) == state.canonicalTopicID(id) })?.title ?? ""
            if lifecycle == .dormant {
                topicActionUndo = TopicActionUndo(
                    label: RecallLocalization.both("已先放下：\(name)", "Paused for today: \(name)"),
                    topicID: id,
                    fallbackTitle: fallbackTitle,
                    correctionID: nil,
                    previousLifecycle: previous
                )
                noticeMessage = RecallLocalization.both("今天已先放下，可在“记忆 → 已搁置”随时恢复。", "Paused for today. Resume anytime under Memory → Shelved.")
            } else if lifecycle == .active || lifecycle == nil {
                topicActionUndo = TopicActionUndo(
                    label: RecallLocalization.both("已恢复跟进：\(name)", "Resumed: \(name)"),
                    topicID: id,
                    fallbackTitle: fallbackTitle,
                    correctionID: nil,
                    previousLifecycle: previous
                )
                noticeMessage = RecallLocalization.both("已恢复到推进中。", "Resumed to in progress.")
            }
            return true
        } catch {
            recordError(error, source: "Memory", message: "更新主题状态失败")
            noticeMessage = RecallLocalization.both("未能更新状态，请重试。", "Could not update topic status. Please retry.")
            return false
        }
    }

    @discardableResult
    func reopenTopic(_ file: MatterFile) async -> Bool {
        let canonical = state.canonicalTopicID(file.id)
        let previousLifecycle = state.topicRegistry.resolvedTopic(for: file)?.manualLifecycle
        let completionCorrections = state.matterCorrections.filter {
            $0.isTopicCompletion && state.canonicalTopicID($0.topicID ?? "") == canonical
        }
        do {
            for correction in completionCorrections {
                try await store.removeMatterCorrection(id: correction.id)
            }
            try await store.setTopicLifecycle(id: file.id, fallbackTitle: file.title, lifecycle: .active)
            state = await store.snapshot()
            rebuildMatterFiles()
            topicActionUndo = TopicActionUndo(
                label: RecallLocalization.both("已恢复跟进：\(file.title)", "Resumed: \(file.title)"),
                topicID: file.id,
                fallbackTitle: file.title,
                correctionID: nil,
                previousLifecycle: previousLifecycle,
                restoredCorrections: completionCorrections
            )
            noticeMessage = RecallLocalization.both("已恢复跟进。", "Resumed.")
            return true
        } catch {
            recordError(error, source: "Memory", message: "恢复主题跟进失败")
            noticeMessage = RecallLocalization.both("未能恢复跟进，请重试。", "Could not reopen topic. Please retry.")
            return false
        }
    }

    func undoTopicAction() {
        guard let undo = topicActionUndo else { return }
        topicActionUndo = nil
        Task {
            do {
                if !undo.restoredCorrections.isEmpty {
                    try await store.setTopicLifecycle(id: undo.topicID, fallbackTitle: undo.fallbackTitle, lifecycle: undo.previousLifecycle)
                    for correction in undo.restoredCorrections {
                        try await store.saveMatterCorrection(correction)
                    }
                    state = await store.snapshot()
                    applyTopicOverlayInPlace()
                } else if let correctionID = undo.correctionID {
                    try await store.removeMatterCorrection(id: correctionID)
                    if undo.previousLifecycle != nil {
                        try await store.setTopicLifecycle(id: undo.topicID, fallbackTitle: undo.fallbackTitle, lifecycle: undo.previousLifecycle)
                    }
                    state = await store.snapshot()
                    rebuildMatterFiles()
                } else {
                    try await store.setTopicLifecycle(id: undo.topicID, fallbackTitle: undo.fallbackTitle, lifecycle: undo.previousLifecycle)
                    state = await store.snapshot()
                    applyTopicOverlayInPlace()
                }
                noticeMessage = RecallLocalization.both("已撤销刚才的操作。", "Action undone.")
            } catch {
                recordError(error, source: "Memory", message: "撤销主题操作失败")
            }
        }
    }

    func resolveMatterFile(for item: LocalBriefing.ResumeItem) -> MatterFile? {
        if let topicID = item.topicID {
            let canonical = state.canonicalTopicID(topicID)
            if let hit = matterFiles.first(where: { state.canonicalTopicID($0.id) == canonical || $0.id == topicID }) {
                return hit
            }
        }
        if let title = item.topicTitle, !title.isEmpty {
            let key = DailyKnowledgeEngine.topicKey(title)
            if let hit = matterFiles.first(where: { DailyKnowledgeEngine.topicKey($0.title) == key }) {
                return hit
            }
        }
        return nil
    }

    @discardableResult
    func completeResumeItem(_ item: LocalBriefing.ResumeItem) async -> Bool {
        if item.kind == .dueReminder, let id = item.reminderID,
           let reminder = state.reminders.first(where: { $0.id == id }) {
            completeReminder(reminder)
            return true
        }
        guard item.kind == .openMatter else { return false }
        if let file = resolveMatterFile(for: item) {
            return await completeMatter(file)
        }
        let targetID = item.topicID ?? ("topic:" + DailyKnowledgeEngine.topicKey(item.topicTitle ?? item.title))
        guard !item.evidenceIDs.isEmpty, completingMatterIDs.insert(targetID).inserted else { return false }
        defer { completingMatterIDs.remove(targetID) }
        do {
            let label = item.topicTitle ?? item.title
            let correction = MatterCorrection(evidenceIDs: item.evidenceIDs, kind: .completed, text: label, topicID: targetID)
            try await store.saveMatterCorrection(correction)
            state = await store.snapshot()
            applyTopicOverlayInPlace()
            topicActionUndo = TopicActionUndo(
                label: RecallLocalization.both("已标为做完：\(label)", "Marked done: \(label)"),
                topicID: targetID,
                fallbackTitle: label,
                correctionID: correction.id,
                previousLifecycle: nil
            )
            noticeMessage = RecallLocalization.both("已标为做完，可在“已做完”中查看。", "Marked done. Find it in Done.")
            return true
        } catch {
            recordError(error, source: "Memory", message: "完成今日接续事项失败")
            noticeMessage = RecallLocalization.both("未能保存完成状态，请重试。", "Unable to save completion. Please retry.")
            return false
        }
    }

    @discardableResult
    func shelveResumeItem(_ item: LocalBriefing.ResumeItem) async -> Bool {
        guard item.kind == .openMatter else { return false }
        let file = resolveMatterFile(for: item)
        let targetID = file?.id ?? item.topicID ?? ("topic:" + DailyKnowledgeEngine.topicKey(item.topicTitle ?? item.title))
        let title = file?.title ?? item.topicTitle ?? item.title
        return await setTopicLifecycle(id: targetID, fallbackTitle: title, lifecycle: .dormant)
    }

    /// 打开围绕指定主题的会话；传入 `question` 时直接发送用户自己的问题，不传则只切入该主题已有会话而不强制自动发话。
    func openTopicConversation(_ topicID: String, question: String? = nil, fallbackEvidenceIDs: [UUID] = []) {
        let file = matterFiles.first { state.canonicalTopicID($0.id) == state.canonicalTopicID(topicID) || $0.id == topicID }
        let evidence = Set(file?.evidenceIDs ?? fallbackEvidenceIDs)
        let resolvedID = file?.id ?? topicID
        let scope = MemoryQueryScope(topicID: resolvedID, topicEvidenceIDs: evidence.isEmpty ? nil : evidence)
        openAskRequested = true
        if let trimmed = question?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            chatScope = scope
            ask(trimmed)
        } else {
            setChatScope(scope)
        }
    }

    func openTopicInWorkspace(_ topicID: String) {
        topicToOpen = nil
        selectedWorkspaceTopicID = topicID
        openMattersSectionRequested = true
    }
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

