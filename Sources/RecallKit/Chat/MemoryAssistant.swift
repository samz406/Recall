import Foundation

@MainActor
public final class MemoryAssistant {
    private let store: FileMemoryStore
    private let searchEngine: MemorySearchEngine
    private let privacyEngine: PrivacyEngine
    private let contextManager: ConversationContextManager

    public init(
        store: FileMemoryStore,
        searchEngine: MemorySearchEngine = MemorySearchEngine(),
        privacyEngine: PrivacyEngine = PrivacyEngine(),
        contextManager: ConversationContextManager = ConversationContextManager()
    ) {
        self.store = store
        self.searchEngine = searchEngine
        self.privacyEngine = privacyEngine
        self.contextManager = contextManager
    }

    @discardableResult
    public func ask(_ question: String) async throws -> ConversationMessage {
        let state = await store.snapshot()
        let recordsAllowedInChat = state.captures.filter { capture in
            state.rules.first(where: { $0.template == capture.eventTemplate })?.participatesInChat ?? true
        }
        let results = searchEngine.search(MemorySearchQuery(text: question), in: recordsAllowedInChat)
        let retrieved = results.map(\.capture)
        let plan = contextManager.plan(
            history: state.messages,
            existingSummary: state.conversationSummary,
            coveredMessageCount: state.conversationSummaryCoveredMessageCount ?? 0,
            retrievedEvidence: retrieved
        )
        if plan.rollingSummary != state.conversationSummary || plan.coveredMessageCount != (state.conversationSummaryCoveredMessageCount ?? 0) {
            try await store.updateConversationSummary(plan.rollingSummary, coveredMessageCount: plan.coveredMessageCount)
        }

        let request = LLMRequest(
            question: question,
            context: plan.evidence,
            conversationSummary: plan.rollingSummary,
            recentMessages: plan.recentMessages
        )
        let response: LLMAnswer

        switch state.llmConfiguration.provider {
        case .localOnly:
            response = try await ExtractiveMemoryResponder().answer(to: request)
        case .openAICompatible, .anthropicCompatible:
            guard state.privacy.cloudUseEnabled else {
                throw LLMError.serviceError("请先在隐私设置中明确开启云端模型使用。")
            }
            guard let key = try KeychainStore.shared.load(account: state.llmConfiguration.keychainAccount), !key.isEmpty else {
                throw LLMError.missingAPIKey
            }
            let safeContext = privacyEngine.cloudContext(from: plan.evidence, settings: state.privacy)
            let safeSummary = plan.rollingSummary.map(privacyEngine.redact)
            let safeRecentMessages = plan.recentMessages.map { message in
                var copy = message
                copy.content = privacyEngine.redact(copy.content)
                return copy
            }
            response = try await CompatibleLLM(configuration: state.llmConfiguration, apiKey: key).answer(
                to: LLMRequest(
                    question: question,
                    context: safeContext,
                    conversationSummary: safeSummary,
                    recentMessages: safeRecentMessages
                )
            )
        }

        let userMessage = ConversationMessage(role: .user, content: question)
        let assistantMessage = ConversationMessage(role: .assistant, content: response.content, citations: response.citedCaptureIDs)
        try await store.addMessage(userMessage)
        try await store.addMessage(assistantMessage)
        return assistantMessage
    }
}
