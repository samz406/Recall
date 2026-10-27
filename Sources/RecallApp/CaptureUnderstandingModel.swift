import Foundation
import RecallKit

@MainActor
extension RecallAppModel {
    func setCaptureUnderstandingEnabled(_ enabled: Bool) {
        if !enabled { captureUnderstandingTask?.cancel() }
        Task {
            do {
                var settings = state.understandingSettings; settings.enabled = enabled
                try await store.updateCaptureUnderstandingSettings(settings)
                await refresh()
            } catch { recordError(error, source: "Understanding", message: "保存记录整理设置失败") }
        }
    }
    func queueCaptureUnderstanding(captureID: UUID? = nil, retryFailed: Bool = false) {
        Task {
            do {
                var count = 0
                if retryFailed {
                    for job in state.understandingJobs where job.state == .failed {
                        count += try await store.enqueueCaptureUnderstanding(captureID: job.captureID, force: true)
                    }
                } else {
                    let start = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
                    count = try await store.enqueueCaptureUnderstanding(since: start, captureID: captureID, force: captureID != nil)
                }
                noticeMessage = count > 0 ? "已加入 \(count) 条记录，将在后台逐段整理。" : "所选范围没有需要整理的新记录。"
                await refresh()
            } catch { noticeMessage = error.localizedDescription; recordError(error, source: "Understanding", message: "添加整理任务失败") }
        }
    }
    func removeCaptureUnderstanding(_ id: UUID) {
        Task {
            do { try await store.removeCaptureUnderstanding(id); await refresh(); noticeMessage = "已删除整理结果，原始记录仍保留。" }
            catch { recordError(error, source: "Understanding", message: "删除整理结果失败") }
        }
    }
    func startCaptureUnderstandingWorker() {
        if captureUnderstandingTimer == nil {
            captureUnderstandingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.startCaptureUnderstandingWorker() }
            }
        }
        guard captureUnderstandingTask == nil, !isGeneratingDailySummary, !isGeneratingWeeklyReview, topicReviewTask == nil, state.understandingSettings.enabled else { return }
        captureUnderstandingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.captureUnderstandingTask = nil }
            do {
                _ = try await store.enqueueCaptureUnderstanding()
                // One bounded page per tick; no archive-sized model request or UI wait.
                guard let job = try await store.claimCaptureUnderstanding() else {
                    self.state = await store.snapshot(); return
                }
                let snapshot = await store.snapshot()
                self.state = snapshot
                let config = snapshot.llmConfiguration
                let taskID = beginTask("整理记录", target: "后台理解", phase: "核对第 \(job.nextPage + 1) / \(job.pageCount) 段")
                let store = self.store
                do {
                    let page = try await store.captureUnderstandingPage(job)
                    let result = try await CaptureUnderstandingEngine.understand(page,
                        responder: CompatibleLLM(configuration: config, apiKey: config.apiKey), beforeCall: {
                            try await store.validateCaptureUnderstandingJob(job, configuration: config, privacy: snapshot.privacy)
                        })
                    try await store.finishCaptureUnderstandingPage(job, result: result, configuration: config, privacy: snapshot.privacy)
                    finishTask(taskID, state: .succeeded, message: job.nextPage + 1 == job.pageCount ? "已保存核对结果" : "本段已保存，稍后继续下一段")
                    self.state = await store.snapshot()
                    self.rebuildMatterFiles()
                    self.discoverReminders(force: false, announce: false)
                } catch {
                    let changed = error is CancellationError || (error as? CaptureUnderstandingError).map {
                        if case .changed = $0 { return true }; return false
                    } == true
                    try await store.failCaptureUnderstanding(job, changed: changed)
                    // Provider errors may contain request/response text. Log a safe category only.
                    recordError(changed ? CaptureUnderstandingError.changed : CaptureUnderstandingError.invalid,
                        source: "Understanding", message: changed ? "记录整理已暂停或输入已变化" : "记录整理未完成，原文保留；最多自动重试三次")
                    finishTask(taskID, state: .failed, message: changed ? "本次已停止，保留已完成的记录" : "未通过核对或连接失败，将按重试策略继续")
                    self.state = await store.snapshot()
                }
            } catch {
                recordError(error, source: "Understanding", message: "后台整理任务保存失败，将稍后重试")
            }
        }
    }
}
