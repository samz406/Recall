import Foundation

extension FileMemoryStore {
    /// Consumes one pending day from `pendingPersonaRefresh`, calling the model once over that day's
    /// already-generated review text (never raw captures) to extract trait signals, then merges the
    /// result locally. Returns `false` once the queue is empty. Best-effort: a failed day is dropped
    /// rather than retried forever, since this is a background refinement, not a user-waited task.
    @discardableResult
    public func refreshPersonaProfile(responder: any LLMResponding, now: Date = .now) async throws -> Bool {
        guard let id = state.pendingPersonaRefresh.first else { return false }
        guard let summary = state.dailySummaries.first(where: { $0.id == id }) else {
            try dropPendingPersonaRefresh(id)
            return true
        }
        guard state.privacy.cloudUseEnabled, state.llmConfiguration.provider != .localOnly, state.llmConfiguration.hasCredential else {
            try dropPendingPersonaRefresh(id)
            return true
        }
        let engine = PersonaInsightEngine()
        let sourceText = engine.sourceText(for: summary)
        // Too little of the day is attributable to the user to responsibly infer anything from it.
        guard sourceText.count >= 24 else {
            try dropPendingPersonaRefresh(id)
            return true
        }
        let context = CaptureRecord(eventTemplate: .manualMoment, contentHash: "persona-insight-" + id.uuidString, ocrText: sourceText)
        let request = LLMRequest(question: engine.prompt(), context: [context], purpose: .personaInsight, outputTokenLimit: 1_200)
        do {
            let answer = try await responder.answerCancellably(to: request)
            let observations = engine.observations(from: answer.content, sourceText: sourceText, day: summary.day, dailySummaryID: summary.id)
                .filter { !state.dismissedPersonaDimensions.contains($0.dimension) }
            try applyPersonaObservations(observations, dayReviewID: id, now: now)
        } catch {
            try? dropPendingPersonaRefresh(id)
            if ModelCallCancellation.isCancellation(error) { throw CancellationError() }
            throw error
        }
        return true
    }

    /// Stops auto-inferring a dimension and removes its current (possibly wrong) trait from display.
    /// Mirrors the existing "不再记住" convention: reversible, and does not touch other dimensions.
    public func dismissPersonaTrait(_ dimension: PersonaDimension) throws {
        state.personaTraits.removeAll { $0.dimension == dimension }
        state.dismissedPersonaDimensions = Array(Set(state.dismissedPersonaDimensions + [dimension]))
        state.personaMatch = PersonaProfileEngine.match(state.personaTraits, excludingArchetypeIDs: Set(state.dismissedPersonaArchetypeIDs))
        try persistReviewState()
    }

    public func resumePersonaTrait(_ dimension: PersonaDimension) throws {
        state.dismissedPersonaDimensions.removeAll { $0 == dimension }
        try persistReviewState()
    }

    /// "这不像我": excludes the current archetype from future matching and immediately recomputes
    /// the next-best one from the same, unchanged trait evidence.
    public func dismissPersonaMatch() throws {
        guard let current = state.personaMatch else { return }
        state.dismissedPersonaArchetypeIDs = Array(Set(state.dismissedPersonaArchetypeIDs + [current.archetypeID]))
        state.personaMatch = PersonaProfileEngine.match(state.personaTraits, excludingArchetypeIDs: Set(state.dismissedPersonaArchetypeIDs))
        try persistReviewState()
    }

    private func dropPendingPersonaRefresh(_ id: UUID) throws {
        state.pendingPersonaRefresh.removeAll { $0 == id }
        try persistReviewState()
    }

    private func applyPersonaObservations(_ observations: [PersonaTraitObservation], dayReviewID: UUID, now: Date) throws {
        state.pendingPersonaRefresh.removeAll { $0 == dayReviewID }
        guard !observations.isEmpty else {
            try persistReviewState()
            return
        }
        state.personaTraitObservations = Array((state.personaTraitObservations + observations).suffix(400))
        state.personaTraits = PersonaProfileEngine.merge(existing: state.personaTraits, with: observations, now: now)
        state.personaMatch = PersonaProfileEngine.match(state.personaTraits, excludingArchetypeIDs: Set(state.dismissedPersonaArchetypeIDs), now: now)
        if let match = state.personaMatch, state.personaMatchHistory.last?.archetypeID != match.archetypeID {
            state.personaMatchHistory = Array((state.personaMatchHistory + [match]).suffix(60))
        }
        try persistReviewState()
    }
}
