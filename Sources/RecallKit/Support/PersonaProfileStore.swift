import Foundation

extension FileMemoryStore {
    /// One review revision per checkpoint, coalesced across callers. Cancellation preserves the checkpoint.
    @discardableResult
    public func refreshPersonaProfile(responder: any LLMResponding, now: Date = .now) async throws -> Bool {
        guard !personaRefreshInFlight else { return false }
        state.reconcilePersonaProfile(now: now)
        guard state.personaProfileSettings.enabled, state.privacy.cloudUseEnabled,
              state.llmConfiguration.provider != .localOnly, state.llmConfiguration.hasCredential,
              let index = state.personaRefreshJobs.firstIndex(where: {
                  $0.status == .queued || ($0.status == .failed && $0.attempts < 3 && ($0.retryAt ?? .distantFuture) <= now)
              }) else { return false }
        let job = state.personaRefreshJobs[index]
        guard let summary = state.dailySummaries.first(where: { $0.id == job.summaryID }) else { return false }
        personaRefreshInFlight = true
        defer { personaRefreshInFlight = false }
        let baseline = state, engine = PersonaInsightEngine(), evidence = engine.evidence(for: summary)
        guard evidence.reduce(0, { $0 + $1.quote.count }) >= 24 else {
            state.personaRefreshJobs[index].status = .insufficientEvidence
            try persistReviewState(); return true
        }
        state.personaRefreshJobs[index].status = .running
        try persistReviewState()
        let context = CaptureRecord(eventTemplate: .manualMoment, contentHash: "persona-" + job.sourceVersion,
            ocrText: engine.text(evidence))
        let request = LLMRequest(question: engine.prompt(excluding: Set(state.dismissedPersonaDimensions)), context: [context], purpose: .personaInsight, outputTokenLimit: 1_200)
        do {
            try validatePersonaJob(job, baseline: baseline)
            let answer = try await responder.answerCancellably(to: request)
            try Task.checkCancellation(); try validatePersonaJob(job, baseline: baseline)
            let observations = try engine.observations(from: answer.content, evidence: evidence, day: summary.day,
                dailySummaryID: summary.id, sourceVersion: job.sourceVersion)
                .filter { !state.dismissedPersonaDimensions.contains($0.dimension) && !Set(state.rejectedPersonaEvidence).contains(PersonaProfileEngine.evidenceKey($0)) }
            guard let live = state.personaRefreshJobs.firstIndex(where: { $0.summaryID == job.summaryID && $0.sourceVersion == job.sourceVersion }) else { throw PersonaInsightError.changed }
            state.personaTraitObservations.removeAll { Calendar.current.isDate($0.day, inSameDayAs: summary.day) }
            state.personaTraitObservations += observations
            state.personaRefreshJobs[live].status = observations.isEmpty ? .insufficientEvidence : .completed
            state.personaRefreshJobs[live].failure = nil; state.personaRefreshJobs[live].retryAt = nil
            state.reconcilePersonaProfile(now: now)
            if let match = state.personaMatch, state.personaMatchHistory.last?.archetypeID != match.archetypeID {
                state.personaMatchHistory = Array((state.personaMatchHistory + [match]).suffix(30))
            }
            try persistReviewState()
        } catch {
            guard state.personaProfileRevision == baseline.personaProfileRevision,
                  let live = state.personaRefreshJobs.firstIndex(where: { $0.summaryID == job.summaryID && $0.sourceVersion == job.sourceVersion }) else { return true }
            if ModelCallCancellation.isCancellation(error) || error is PersonaWorkDeferred || (error as? PersonaInsightError) == .changed {
                state.personaRefreshJobs[live].status = .queued
                // The caller's task may already be cancelled. Persist the resumable checkpoint without that check.
                try persist()
                if ModelCallCancellation.isCancellation(error) { throw CancellationError() }
                return false
            }
            state.personaRefreshJobs[live].status = .failed
            state.personaRefreshJobs[live].attempts += 1
            state.personaRefreshJobs[live].failure = error is PersonaInsightError ? "format" : "service"
            state.personaRefreshJobs[live].retryAt = now.addingTimeInterval(state.personaRefreshJobs[live].attempts == 1 ? 30 : 120)
            try persistReviewState()
        }
        return true
    }

    private func validatePersonaJob(_ job: PersonaRefreshJob, baseline: RecallState) throws {
        try Task.checkCancellation()
        guard state.personaProfileRevision == baseline.personaProfileRevision,
              state.personaProfileSettings.enabled, state.privacy.cloudUseEnabled, state.privacy == baseline.privacy,
              state.llmConfiguration == baseline.llmConfiguration,
              state.workflow.identityBindings == baseline.workflow.identityBindings,
              state.matterCorrections == baseline.matterCorrections,
              let summary = state.dailySummaries.first(where: { $0.id == job.summaryID }),
              state.personaSourceVersion(summary) == job.sourceVersion,
              state.personaRefreshJobs.contains(where: { $0.summaryID == job.summaryID && $0.sourceVersion == job.sourceVersion }) else { throw PersonaInsightError.changed }
    }
    public func setPersonaProfileEnabled(_ enabled: Bool) throws {
        state.personaProfileSettings.enabled = enabled; state.personaProfileRevision = UUID()
        for i in state.personaRefreshJobs.indices where state.personaRefreshJobs[i].status == .running { state.personaRefreshJobs[i].status = .queued }
        try persistReviewState()
    }
    public func setPersonaPersonalization(_ enabled: Bool) throws {
        state.personaProfileSettings.personalizesResponses = enabled; state.personaProfileRevision = UUID()
        state.conversationSummary = nil
        try persistReviewState()
    }
    public func clearPersonaProfile(rebuild: Bool = false) throws {
        state.personaProfileRevision = UUID(); state.personaProfileSettings.enabled = rebuild
        state.personaTraitObservations = []; state.personaTraits = []; state.personaMatch = nil; state.personaMatchHistory = []
        state.personaRefreshJobs = []; state.pendingPersonaRefresh = []
        state.rejectedPersonaEvidence = []; state.rejectedPersonaMatchStamp = nil
        state.dismissedPersonaDimensions = []; state.dismissedPersonaArchetypeIDs = []
        state.conversationSummary = nil
        state.pendingRecoveryCleanup = true
        try persist()
    }
    public func retryPersonaRefresh() throws {
        for i in state.personaRefreshJobs.indices where state.personaRefreshJobs[i].status == .failed {
            state.personaRefreshJobs[i].status = .queued; state.personaRefreshJobs[i].attempts = 0
            state.personaRefreshJobs[i].failure = nil; state.personaRefreshJobs[i].retryAt = nil
        }
        try persistReviewState()
    }
    public func dismissPersonaTrait(_ dimension: PersonaDimension) throws {
        state.dismissedPersonaDimensions = Array(Set(state.dismissedPersonaDimensions + [dimension])).sorted { $0.rawValue < $1.rawValue }
        state.conversationSummary = nil
        try persistReviewState()
    }
    public func resumePersonaTrait(_ dimension: PersonaDimension) throws {
        state.dismissedPersonaDimensions.removeAll { $0 == dimension }
        try persistReviewState()
    }
    /// Corrects specific evidence instead of silently substituting a different personality label.
    public func rejectPersonaEvidence(_ ids: Set<UUID>) throws {
        let keys = state.personaTraitObservations.filter { ids.contains($0.id) }.map(PersonaProfileEngine.evidenceKey)
        state.rejectedPersonaEvidence = Array(Set(state.rejectedPersonaEvidence + keys)).sorted()
        state.personaTraitObservations.removeAll { ids.contains($0.id) }
        state.personaProfileRevision = UUID(); state.conversationSummary = nil; state.personaMatchHistory = []
        state.pendingRecoveryCleanup = true
        try persist()
    }
    public func dismissPersonaMatch() throws {
        guard let current = state.personaMatch else { return }
        state.dismissedPersonaArchetypeIDs = Array(Set(state.dismissedPersonaArchetypeIDs + [current.archetypeID])).sorted()
        state.rejectedPersonaMatchStamp = state.personaEvidenceStamp
        state.personaMatch = nil
        try persistReviewState()
    }
    public func restorePersonaMatches() throws {
        state.dismissedPersonaArchetypeIDs = []; state.rejectedPersonaMatchStamp = nil
        try persistReviewState()
    }
}
