import Foundation

public struct DirectDailyReviewOutcome: Sendable {
    public var summary: DailySummary
    public var metrics: DailyReviewMetrics
    public var reminders = DailyReminderSync()
}

public enum DailyReviewGenerationPolicy: Sendable {
    case replaceExisting, fillMissing, scheduled
}

public enum DailyReviewSkipped: Error {
    case alreadySaved, alreadyAttempted, inProgress, scheduleDisabled
}

extension RecallState {
    public func dailyReview(on day: Date, calendar: Calendar = .current) -> DailySummary? {
        dailySummaries.first { calendar.isDate($0.day, inSameDayAs: day) }
    }

    public func hasAttemptedDailyReview(on day: Date, calendar: Calendar = .current) -> Bool {
        dailyReviewAttemptedDays.contains { calendar.isDate($0, inSameDayAs: day) }
    }
}

private actor DailyReviewMeter: LLMResponding {
    let responder: any LLMResponding
    var metrics = DailyReviewMetrics()
    init(_ responder: any LLMResponding) { self.responder = responder }
    func answer(to request: LLMRequest) async throws -> LLMAnswer {
        try Task.checkCancellation()
        metrics.modelCalls += 1
        metrics.inputBytes += request.question.utf8.count + request.context.reduce(0) { $0 + $1.ocrText.utf8.count }
        let start = Date.now
        defer { metrics.modelMilliseconds += Self.milliseconds(since: start) }
        return try await responder.answerCancellably(to: request)
    }
    func prepared(_ input: DailyReviewInput, milliseconds: Int) {
        metrics.sourceCount = input.recordIDs.count; metrics.documentCount = input.documents.count
        metrics.reusedRecords = input.reusedRecords; metrics.readMilliseconds = milliseconds
    }
    func hit() { metrics.cacheHits += 1 }
    func finish(start: Date, saveMilliseconds: Int = 0) -> DailyReviewMetrics {
        metrics.totalMilliseconds = Self.milliseconds(since: start); metrics.saveMilliseconds = saveMilliseconds
        return metrics
    }
    static func milliseconds(since start: Date) -> Int { max(0, Int(Date.now.timeIntervalSince(start) * 1000)) }
}

extension FileMemoryStore {
    /// The app's single entry point for manual, scheduled and retried daily reviews.
    /// This never prepares per-capture understanding or invokes independent model audits.
    public func generateDirectDailyReview(day: Date, period: ReviewPeriod, responder: any LLMResponding,
                                          policy: DailyReviewGenerationPolicy = .replaceExisting,
                                          expectedConfiguration: LLMConfiguration? = nil, expectedPrivacy: PrivacySettings? = nil,
                                          limits: DailyReviewLimits = DailyReviewLimits(),
                                          onProgress: (@Sendable (ReviewGenerationProgress) async -> Void)? = nil,
                                          onMetrics: (@Sendable (DailyReviewMetrics) async -> Void)? = nil) async throws -> DirectDailyReviewOutcome {
        let start = Date.now, meter = DailyReviewMeter(responder)
        let calendar = Calendar.current
        let reviewDay = calendar.startOfDay(for: day)
        do {
            try Task.checkCancellation()
            let original = state.dailyReview(on: reviewDay, calendar: calendar)
            if policy != .replaceExisting, original != nil { throw DailyReviewSkipped.alreadySaved }
            if policy == .scheduled {
                guard state.dailySummarySettings.isEnabled else { throw DailyReviewSkipped.scheduleDisabled }
                guard !state.hasAttemptedDailyReview(on: reviewDay, calendar: calendar) else { throw DailyReviewSkipped.alreadyAttempted }
            }
            guard state.privacy.cloudUseEnabled, state.llmConfiguration.provider != .localOnly, state.llmConfiguration.hasCredential,
                  expectedConfiguration == nil || state.llmConfiguration == expectedConfiguration,
                  expectedPrivacy == nil || state.privacy == expectedPrivacy else { throw ModelReviewError.unavailable }
            guard activeDailyReviewDays.insert(reviewDay).inserted else { throw DailyReviewSkipped.inProgress }
            defer { activeDailyReviewDays.remove(reviewDay) }

            // Claim the date before requesting the model. Even a failed or interrupted attempt
            // can then only be repeated by an explicit user action.
            try recordDailyReviewAttempt(on: reviewDay, now: start, calendar: calendar)
            let baseline = state
            await onProgress?(ReviewGenerationProgress(.preparing, detail: "正在读取所选日期的材料；已有整理直接复用，其余使用脱敏原文。"))
            let preparation = Task.detached(priority: .userInitiated) { try DailyReviewInput.make(in: baseline, period: period) }
            let input = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
            await meter.prepared(input, milliseconds: DailyReviewMeter.milliseconds(since: start))
            try validateDirectDailyReview(input, baseline: baseline)
            let checkpoints = state.dailyReviewCheckpoints.filter { checkpoint in
                checkpoint.configurationVersion == input.configurationVersion && checkpoint.feedbackRevision == input.feedbackRevision
                    && Date.now.timeIntervalSince(checkpoint.createdAt) <= 7 * 86_400
                    && checkpoint.sourceVersions.allSatisfy { input.sourceVersions[$0.key] == $0.value }
            }
            let result = try await DirectDailyReviewEngine(limits: limits).generate(input, checkpoints: checkpoints,
                beforeCall: { try await self.validateDirectDailyReview(input, baseline: baseline) },
                saveCheckpoint: { try await self.saveDailyReviewCheckpoint($0, input: input, baseline: baseline) },
                onProgress: onProgress, onCacheHit: { await meter.hit() }, responder: meter)
            try Task.checkCancellation(); try validateDirectDailyReview(input, baseline: baseline)
            guard !result.items.isEmpty else { throw WeeklyReviewError.noEvidence }
            var summary = result.dailySummary(day: day)
            let contextIDs = DailyReviewReminderEngine.contextIDs(input.reminderContext)
            for i in summary.items.indices {
                if let id = summary.items[i].knowledge?.reminderID,
                   contextIDs.contains(id), let original = baseline.reminders.first(where: { $0.id == id }) {
                    summary.items[i].knowledge?.reminderRevision = SummaryFeedbackLearning.hash(original)
                } else { summary.items[i].knowledge?.reminderID = nil }
            }
            await onProgress?(ReviewGenerationProgress(.saving, detail: "回顾已生成，本地来源和格式校验通过，正在保存。"))
            try Task.checkCancellation(); try validateDirectDailyReview(input, baseline: baseline)
            let old = state.dailyReview(on: reviewDay, calendar: calendar)
            if policy != .replaceExisting, old != nil { throw DailyReviewSkipped.alreadySaved }
            guard old?.id == original?.id, old?.content == original?.content else { throw ModelReviewError.changed }
            let saveStart = Date.now, previous = state
            var saved = summary
            if let old {
                saved.versions = Array(([DailyReviewVersion(summary: old)] + (old.versions ?? [])).prefix(8))
                saved.sourceCaptureIDs = Array(Set(saved.sourceCaptureIDs + (saved.versions ?? []).flatMap(\.sourceIDs)))
            }
            state.dailySummaries.removeAll { calendar.isDate($0.day, inSameDayAs: reviewDay) }
            state.dailySummaries.append(saved); state.dailySummaries.sort { $0.day > $1.day }
            let liveSummaries = Set(state.dailySummaries.map(\.id))
            state.pendingDailyReviewMaintenance.removeAll { !liveSummaries.contains($0) }
            state.pendingDailyReviewMaintenance.append(saved.id)
            let reminders = DailyReviewReminderEngine.reconcile(&state)
            do { try persistReviewState(indexChanged: true) } catch { state = previous; throw error }
            let metrics = await meter.finish(start: start, saveMilliseconds: DailyReviewMeter.milliseconds(since: saveStart))
            await onMetrics?(metrics)
            return DirectDailyReviewOutcome(summary: saved, metrics: metrics, reminders: reminders)
        } catch let skip as DailyReviewSkipped {
            throw skip
        } catch {
            let metrics = await meter.finish(start: start)
            await onMetrics?(metrics)
            if ModelCallCancellation.isCancellation(error) { throw CancellationError() }
            throw error
        }
    }

    private func recordDailyReviewAttempt(on day: Date, now: Date, calendar: Calendar) throws {
        let today = calendar.startOfDay(for: now)
        guard let earliest = calendar.date(byAdding: .day, value: -DailySummarySettings.automaticLookbackDays, to: today),
              (earliest...today).contains(day), !state.hasAttemptedDailyReview(on: day, calendar: calendar) else { return }
        let previous = state
        state.dailyReviewAttemptedDays = state.dailyReviewAttemptedDays.filter { (earliest...today).contains($0) } + [day]
        do { try persistReviewState(invalidateAnalysis: false) } catch { state = previous; throw error }
    }

    private func validateDirectDailyReview(_ input: DailyReviewInput, baseline: RecallState) throws {
        try Task.checkCancellation()
        guard state.privacy.cloudUseEnabled, state.privacy == baseline.privacy, state.llmConfiguration == baseline.llmConfiguration,
              state.matterCorrections == baseline.matterCorrections,
              SummaryFeedbackLearning.revision(in: state) == input.feedbackRevision,
              Set(ModelReviewEvidence.records(in: state, period: input.period).map(\.id)) == input.recordIDs else { throw ModelReviewError.changed }
        let live = Dictionary(uniqueKeysWithValues: state.captures.map { ($0.id, $0) })
        guard input.sourceVersions.allSatisfy({ id, version in
            guard let source = live[id], !state.privacy.excludedBundleIdentifiers.contains(source.sourceBundleIdentifier ?? "") else { return false }
            return CaptureUnderstandingEngine.sourceVersion(source, in: state) == version
        }) else { throw ModelReviewError.changed }
    }
    private func saveDailyReviewCheckpoint(_ checkpoint: DailyReviewCheckpoint, input: DailyReviewInput, baseline: RecallState) throws {
        try validateDirectDailyReview(input, baseline: baseline)
        let previous = state
        state.dailyReviewCheckpoints.removeAll { $0.key == checkpoint.key }
        state.dailyReviewCheckpoints.append(checkpoint)
        state.dailyReviewCheckpoints = Array(state.dailyReviewCheckpoints.suffix(128))
        do { try persistReviewState() } catch { state = previous; throw error }
    }
    func reconcileDailyReviewCheckpoints(now: Date = .now) {
        let liveSummaries = Set(state.dailySummaries.map(\.id))
        state.pendingDailyReviewMaintenance.removeAll { !liveSummaries.contains($0) }
        guard state.privacy.cloudUseEnabled else { state.dailyReviewCheckpoints = []; return }
        guard !state.dailyReviewCheckpoints.isEmpty else { return }
        let configuration = DailyReviewInput.configurationVersion(state.llmConfiguration)
        let revision = SummaryFeedbackLearning.revision(in: state)
        let tracked = Set(state.dailyReviewCheckpoints.flatMap { $0.sourceVersions.keys })
        let excluded = Set(state.matterCorrections.filter { $0.kind == .notMine || $0.kind == .inaccurate }.flatMap(\.evidenceIDs))
        let versions = Dictionary(uniqueKeysWithValues: state.captures.filter {
            tracked.contains($0.id) && !excluded.contains($0.id) && !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "")
        }.map { ($0.id, CaptureUnderstandingEngine.sourceVersion($0, in: state)) })
        state.dailyReviewCheckpoints.removeAll { checkpoint in
            checkpoint.configurationVersion != configuration || checkpoint.feedbackRevision != revision
                || now.timeIntervalSince(checkpoint.createdAt) > 7 * 86_400
                || !checkpoint.sourceVersions.allSatisfy { versions[$0.key] == $0.value }
        }
    }
    /// Drained by the existing local maintenance cycle, not the user's model wait.
    func finishPendingDailyReviewMaintenance() {
        guard let id = state.pendingDailyReviewMaintenance.first else { return }
        state.pendingDailyReviewMaintenance.removeFirst()
        guard let summary = state.dailySummaries.first(where: { $0.id == id }) else { return }
        projectDayFromMatters(summary.day)
    }
}

