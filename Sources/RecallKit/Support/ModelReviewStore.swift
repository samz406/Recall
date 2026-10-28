import Foundation

extension FileMemoryStore {
    /// Explicit generation prepares only this range. Pausing automatic processing does not
    /// prevent a user-requested review; the cloud permission always applies to every call.
    public func prepareModelReview(period: ReviewPeriod, sourceIDs: Set<UUID>? = nil,
                                   responder: any LLMResponding,
                                   expectedConfiguration: LLMConfiguration? = nil, expectedPrivacy: PrivacySettings? = nil,
                                   onPhase: (@Sendable (String) async -> Void)? = nil,
                                   onProgress: (@Sendable (ReviewGenerationProgress) async -> Void)? = nil) async throws -> RecallState {
        try Task.checkCancellation()
        guard state.privacy.cloudUseEnabled, state.llmConfiguration.provider != .localOnly,
              !state.llmConfiguration.apiKey.isEmpty else { throw ModelReviewError.unavailable }
        guard expectedConfiguration == nil || state.llmConfiguration == expectedConfiguration,
              expectedPrivacy == nil || state.privacy == expectedPrivacy else { throw ModelReviewError.changed }
        let baseline = state
        let records = ModelReviewEvidence.records(in: baseline, period: period, sourceIDs: sourceIDs)
        guard !records.isEmpty else { throw WeeklyReviewError.noEvidence }
        let reused = records.filter { record in
            (record.manualMatter != nil && record.textOrigin == .userInput)
                || record.understanding.map { CaptureUnderstandingEngine.isCurrent($0, in: baseline) } == true
        }.count
        await onPhase?("准备记录")
        await onProgress?(ReviewGenerationProgress(.preparing, detail: "范围内有 \(records.count) 条记录，\(reused) 条可直接复用；仅补齐未处理的记录。"))
        let expected = Dictionary(uniqueKeysWithValues: records.map { ($0.id, CaptureUnderstandingEngine.sourceVersion($0, in: baseline)) })
        for (offset, record) in records.enumerated() {
            try Task.checkCancellation()
            try validateReviewPreparation(expected, baseline: baseline)
            if record.manualMatter != nil && record.textOrigin == .userInput { continue }
            if let result = state.captures.first(where: { $0.id == record.id })?.understanding,
               CaptureUnderstandingEngine.isCurrent(result, in: state) { continue }
            if state.understandingJobs.contains(where: { $0.captureID == record.id && $0.state == .discarded }) { throw ModelReviewError.declined }
            // Reuse completed pages after interruption. An explicitly retried failed job
            // resumes from its last saved page rather than restarting a long document.
            if let i = state.understandingJobs.firstIndex(where: { $0.captureID == record.id }),
               [.failed, .retrying, .paused, .completed].contains(state.understandingJobs[i].state) {
                let before = state
                if state.understandingJobs[i].state == .completed { state.understandingJobs[i] = CaptureUnderstandingJob(captureID: record.id) }
                else { state.understandingJobs[i].state = .queued; state.understandingJobs[i].attempts = 0; state.understandingJobs[i].retryAt = nil }
                do { try persist() } catch { state = before; throw error }
            }
            _ = try enqueueCaptureUnderstanding(captureID: record.id, forReview: true)
            while true {
                try Task.checkCancellation(); try validateReviewPreparation(expected, baseline: baseline)
                if let ready = state.captures.first(where: { $0.id == record.id })?.understanding,
                   CaptureUnderstandingEngine.isCurrent(ready, in: state) { break }
                guard let job = try claimCaptureUnderstanding(captureID: record.id, forReview: true) else {
                    if state.understandingJobs.contains(where: { $0.captureID == record.id && $0.state == .processing }) {
                        try await Task.sleep(for: .milliseconds(250)); continue
                    }
                    throw ModelReviewError.incomplete
                }
                let detail = "准备第 \(offset + 1)/\(records.count) 条记录 · 第 \(job.nextPage + 1)/\(job.pageCount) 段；已保存的段落不会重复处理。"
                await onProgress?(ReviewGenerationProgress(.preparing, detail: detail))
                do {
                    let outcome = try await processCaptureUnderstandingPage(job, responder: responder,
                        configuration: baseline.llmConfiguration, privacy: baseline.privacy, forReview: true, beforeCall: {
                        try await self.validateReviewPreparation(expected, baseline: baseline)
                    }, onRepair: { issue in
                        await onProgress?(ReviewGenerationProgress(.preparing, detail: "\(detail)\n\(issue.explanation)，正在自动修正一次。"))
                    })
                    if case .subdivided = outcome {
                        await onProgress?(ReviewGenerationProgress(.preparing,
                            detail: "第 \(offset + 1)/\(records.count) 条记录超出模型单次容量，已拆成更小段继续；原文和已完成进度保留。"))
                    }
                } catch {
                    // Preserve cursor and accepted pages on cancellation. Changed sources will
                    // be reset by the normal source-version reconciliation.
                    if ModelCallCancellation.isCancellation(error) {
                        try releaseCaptureUnderstanding(job, pause: true)
                        throw CancellationError()
                    }
                    let changed = (error as? CaptureUnderstandingError).map { if case .changed = $0 { true } else { false } } ?? false
                    let reviewChanged = (error as? ModelReviewError).map { if case .changed = $0 { true } else { false } } ?? false
                    try failCaptureUnderstanding(job, changed: changed || reviewChanged, error: error)
                    if changed || reviewChanged { throw error }
                    throw ReviewPreparationFailure(record: offset + 1, total: records.count, page: job.nextPage + 1,
                        pageCount: job.pageCount, reason: ReviewProcessingDiagnostics.reason(for: error), code: ReviewProcessingDiagnostics.code(for: error))
                }
            }
        }
        try validateReviewPreparation(expected, baseline: baseline)
        return state
    }

    func validateReviewPreparation(_ versions: [UUID: String], baseline: RecallState) throws {
        try Task.checkCancellation()
        guard state.privacy.cloudUseEnabled, state.privacy == baseline.privacy,
              state.llmConfiguration == baseline.llmConfiguration,
              state.matterCorrections == baseline.matterCorrections,
              SummaryFeedbackLearning.revision(in: state) == SummaryFeedbackLearning.revision(in: baseline) else { throw ModelReviewError.changed }
        let sources = Dictionary(uniqueKeysWithValues: state.correctedForAnalysis().captures.map { ($0.id, $0) })
        guard versions.allSatisfy({ id, version in
            sources[id].map { CaptureUnderstandingEngine.sourceVersion($0, in: state) == version
                && !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") } ?? false
        }) else { throw ModelReviewError.changed }
    }

    public func validateModelReview(_ expected: RecallState, period: ReviewPeriod, sourceIDs: Set<UUID>? = nil) throws {
        try Task.checkCancellation()
        let oldRecords = ModelReviewEvidence.records(in: expected, period: period, sourceIDs: sourceIDs)
        let currentRecords = ModelReviewEvidence.records(in: state, period: period, sourceIDs: sourceIDs)
        guard Set(oldRecords.map(\.id)) == Set(currentRecords.map(\.id)) else { throw ModelReviewError.changed }
        try validateDailySummaryModelCall(sourceIDs: Set(oldRecords.map(\.id)).union(oldRecords.compactMap(\.understanding).flatMap { $0.sourceVersions.keys }), expected: expected)
    }
}

extension FileMemoryStore {
    public func commitModelDailySummary(_ summary: DailySummary, expected: RecallState, period: ReviewPeriod) throws {
        try Task.checkCancellation()
        try validateModelReview(expected, period: period)
        let consolidation = PersonalIntelligenceEngine().consolidate(day: summary.day, records: state.captures,
            existingEpisodes: state.episodes, previousProjects: state.projects, existingMemories: state.userMemories,
            previousInsights: state.insights, feedback: state.insightFeedback, existingRoutines: state.learnedRoutines)
        try commitDailySummary(summary, consolidation: consolidation)
    }
    public func stopLegacyReviewRefinement(_ report: WeeklyReport, schedule: ReviewSchedule) throws {
        guard let i = state.weeklyReports.firstIndex(where: { $0.id == report.id }), state.reviewSchedules.contains(schedule) else { return }
        let before = state
        state.weeklyReports[i].refinementPending = false
        do { try persist() } catch { state = before; throw error }
    }
}

extension FileMemoryStore {
    /// A newly completed interpretation must not erase a previous review before a new
    /// synthesis succeeds. Never restore after raw edits, corrections, exclusion or deletion.
    func preserveReviewHistory(from previous: RecallState) {
        let current = Dictionary(uniqueKeysWithValues: state.captures.map { ($0.id, $0) })
        let before = Dictionary(uniqueKeysWithValues: previous.captures.map { ($0.id, $0) })
        func unchanged(_ ids: Set<UUID>) -> Bool {
            !ids.isEmpty && ids.allSatisfy { id in
                guard let old = before[id], let source = current[id],
                      !state.privacy.excludedBundleIdentifiers.contains(source.sourceBundleIdentifier ?? "") else { return false }
                return CaptureUnderstandingEngine.sourceVersion(old, in: previous) == CaptureUnderstandingEngine.sourceVersion(source, in: state)
            }
        }
        for report in previous.dailySummaries where unchanged(Set(report.sourceCaptureIDs)) {
            if !state.dailySummaries.contains(where: { $0.id == report.id }) { state.dailySummaries.append(report) }
        }
        state.dailySummaries.sort { $0.day > $1.day }
        for var report in previous.weeklyReports where report.isReadable && unchanged(report.sourceIDs) {
            guard let i = state.weeklyReports.firstIndex(where: { $0.id == report.id }) else { continue }
            report.sourceVersions = Dictionary(uniqueKeysWithValues: report.sourceIDs.compactMap { id in
                WeeklyReviewEngine.sourceVersion(id: id, state: state).map { (id, $0) }
            })
            state.weeklyReports[i] = report
        }
        for var review in previous.topicReviews where unchanged(Set(review.sourceVersions.keys)) {
            review.sourceVersions = Dictionary(uniqueKeysWithValues: review.sourceVersions.keys.compactMap { id in
                WeeklyReviewEngine.sourceVersion(id: id, state: state).map { (id, $0) }
            })
            state.topicReviews.removeAll { $0.id == review.id }; state.topicReviews.append(review)
        }
    }
}
