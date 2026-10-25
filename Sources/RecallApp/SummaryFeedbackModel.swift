import Foundation
import RecallKit

@MainActor
extension RecallAppModel {
    func sendSummaryFeedback(_ target: SummaryFeedbackTarget, text: String) async -> Bool {
        do {
            _ = try await store.submitSummaryFeedback(target: target, text: text)
            await refresh()
            noticeMessage = "反馈已保存，处理结果可在回顾下方查看。"
            return true
        } catch { recordError(error, source: "Feedback", message: "保存反馈失败"); noticeMessage = error.localizedDescription; return false }
    }
    func startSummaryFeedbackWorker() {
        if summaryFeedbackTimer == nil {
            summaryFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.startSummaryFeedbackWorker() }
            }
        }
        guard summaryFeedbackTask == nil else { return }
        summaryFeedbackTask = Task { [weak self] in
            guard let self else { return }
            defer { self.summaryFeedbackTask = nil }
            // A bounded serial batch yields to capture/chat. The durable queue survives closing the app.
            for _ in 0..<3 {
                do {
                    let snapshot = await self.store.snapshot()
                    let config = snapshot.llmConfiguration
                    let available = snapshot.privacy.cloudUseEnabled && config.provider != .localOnly && !config.apiKey.isEmpty
                    guard let job = try await self.store.claimSummaryFeedback(modelAvailable: available) else {
                        self.state = await self.store.snapshot(); break
                    }
                    self.state = await self.store.snapshot()
                    let taskID = self.beginTask("处理反馈", target: job.target.title, phase: "核对反馈与相关记录")
                    let store = self.store
                    do {
                        let working = await store.snapshot()
                        let plan = try await SummaryFeedbackEngine().resolve(job, in: working,
                            responder: CompatibleLLM(configuration: config, apiKey: config.apiKey), beforeCall: { sources in
                                try await store.validateSummaryFeedbackJob(job, configuration: config, privacy: snapshot.privacy, extraSources: sources)
                            })
                        self.updateTask(taskID, phase: "保存核对结果")
                        try await store.finishSummaryFeedback(job, plan: plan, configuration: config, privacy: snapshot.privacy)
                        self.finishTask(taskID, state: plan.resolution.diagnosis == .unclear ? .partial : .succeeded,
                            message: plan.resolution.message, destination: job.target.kind == .daily ? .daily(job.target.reportID) : .review(job.target.reportID))
                    } catch {
                        let changed = (error as? SummaryFeedbackError).map { if case .changed = $0 { return true }; return false } ?? false
                        try await store.failSummaryFeedback(job, changed: changed)
                        self.recordError(error, source: "Feedback", message: "反馈核对未完成，已保留原内容")
                        self.finishTask(taskID, state: .failed, message: "未修改原内容，详情见反馈记录")
                    }
                    await self.refresh()
                } catch { self.recordError(error, source: "Feedback", message: "反馈任务保存失败，将稍后重试"); break }
            }
        }
    }
    func withdrawFeedback(_ id: UUID) {
        Task {
            do { try await store.withdrawSummaryFeedback(id); await refresh() }
            catch { recordError(error, source: "Feedback", message: "撤销反馈失败"); noticeMessage = "未能撤销，请稍后重试。" }
        }
    }
    func deleteFeedback(_ id: UUID) {
        Task {
            do { try await store.deleteSummaryFeedback(id); await refresh() }
            catch { recordError(error, source: "Feedback", message: "删除反馈失败") }
        }
    }
    func retryFeedback(_ id: UUID) {
        Task {
            do { try await store.retrySummaryFeedback(id); await refresh() }
            catch { recordError(error, source: "Feedback", message: "重试反馈失败") }
        }
    }
    func disableFeedbackRule(_ entry: UUID, rule: UUID) {
        Task {
            do { try await store.disableSummaryRule(feedbackID: entry, ruleID: rule); await refresh() }
            catch { recordError(error, source: "Feedback", message: "停用总结偏好失败") }
        }
    }
    func updateFeedbackSettings(_ settings: SummaryFeedbackSettings) {
        Task {
            do { try await store.updateSummaryFeedbackSettings(settings); await refresh() }
            catch { recordError(error, source: "Feedback", message: "保存反馈设置失败") }
        }
    }
}
