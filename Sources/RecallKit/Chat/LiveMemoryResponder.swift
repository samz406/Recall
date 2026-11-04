import Foundation

/// Recheck privacy between planning, reads and verification, not just at the start of a multi-call answer.
struct LiveMemoryResponder: LLMResponding {
    let base: any LLMResponding
    let store: FileMemoryStore
    let original: RecallState
    private func validate() async throws {
        try Task.checkCancellation()
        let live = await store.snapshot()
        guard live.privacy.cloudUseEnabled,
              live.privacy.excludedBundleIdentifiers == original.privacy.excludedBundleIdentifiers,
              live.llmConfiguration == original.llmConfiguration,
              live.matterCorrections == original.matterCorrections,
              live.memoryKnowledgeSettings == original.memoryKnowledgeSettings,
              live.workflow.identityBindings == original.workflow.identityBindings,
              live.dataGeneration == original.dataGeneration,
              live.memoryKnowledge.suppressedKeys == original.memoryKnowledge.suppressedKeys,
              SummaryFeedbackLearning.revision(in: live) == SummaryFeedbackLearning.revision(in: original),
              Set(original.captures.map(\.id)).isSubset(of: Set(live.captures.map(\.id))) else {
            throw LLMError.serviceError(RecallLocalization.both("记忆或隐私设置已变化，请重新提问。", "Memory or privacy settings changed. Ask again to use the current scope."))
        }
        let versions = Dictionary(uniqueKeysWithValues: live.captures.map { ($0.id, $0) })
        guard original.captures.allSatisfy({ source in
            guard let current = versions[source.id] else { return false }
            return (source.correctedText ?? source.ocrText) == (current.correctedText ?? current.ocrText)
        }) else { throw LLMError.serviceError("记忆已更正，请重新提问。") }
    }
    func answer(to request: LLMRequest) async throws -> LLMAnswer {
        try await validate()
        return try await base.answerCancellably(to: request)
    }
    func answerStream(to request: LLMRequest, onText: @escaping @Sendable (String) async -> Void) async throws -> LLMAnswer {
        try await validate()
        return try await base.answerStream(to: request, onText: onText)
    }
}
