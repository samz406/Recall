import Foundation

extension FileMemoryStore {
    /// Called again before a repair/retry: an initial permission check cannot authorize a
    /// later network call after records were removed or cloud use was switched off.
    public func validateDailySummaryModelCall(sourceIDs: Set<UUID>, expected: RecallState) throws {
        guard state.privacy.cloudUseEnabled, state.privacy == expected.privacy,
              state.llmConfiguration == expected.llmConfiguration,
              state.matterCorrections == expected.matterCorrections,
              SummaryFeedbackLearning.revision(in: state) == SummaryFeedbackLearning.revision(in: expected) else {
            throw WeeklyReviewError.changedSources
        }
        let current = state.correctedForAnalysis()
        let live = Dictionary(uniqueKeysWithValues: current.captures.map { ($0.id, $0) })
        let original = Dictionary(uniqueKeysWithValues: expected.captures.map { ($0.id, $0) })
        guard sourceIDs.allSatisfy({ id in
            guard let actual = live[id], let before = original[id],
                  !state.privacy.excludedBundleIdentifiers.contains(actual.sourceBundleIdentifier ?? "") else { return false }
            return MemoryKnowledgeEngine.version(of: actual, corrections: current.matterCorrections)
                == MemoryKnowledgeEngine.version(of: before, corrections: expected.matterCorrections)
        }) else { throw WeeklyReviewError.changedSources }
    }
}
