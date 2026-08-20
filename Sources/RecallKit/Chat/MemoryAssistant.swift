import Foundation

@MainActor
public final class MemoryAssistant {
    private let store: FileMemoryStore
    private let searchEngine: MemorySearchEngine
    private let privacyEngine: PrivacyEngine

    public init(
        store: FileMemoryStore,
        searchEngine: MemorySearchEngine = MemorySearchEngine(),
        privacyEngine: PrivacyEngine = PrivacyEngine()
    ) {
        self.store = store
        self.searchEngine = searchEngine
        self.privacyEngine = privacyEngine
    }

    @discardableResult
    public func ask(_ question: String) async throws -> ConversationMessage {
        let state = await store.snapshot()
        let results = searchEngine.search(MemorySearchQuery(text: question), in: state.captures)
        let retrieved = results.map(\.capture)
        let request = LLMRequest(question: question, context: retrieved)
        let response: LLMAnswer

        switch state.llmConfiguration.provider {
        case .localOnly:
            response = try await ExtractiveMemoryResponder().answer(to: request)
        case .openAICompatible:
            guard state.privacy.cloudUseEnabled else {
                throw LLMError.serviceError("请先在隐私设置中明确开启云端模型使用。")
            }
            guard let key = try KeychainStore.shared.load(account: state.llmConfiguration.keychainAccount), !key.isEmpty else {
                throw LLMError.missingAPIKey
            }
            let safeContext = privacyEngine.cloudContext(from: retrieved, settings: state.privacy)
            response = try await OpenAICompatibleLLM(configuration: state.llmConfiguration, apiKey: key).answer(
                to: LLMRequest(question: question, context: safeContext)
            )
        }

        let userMessage = ConversationMessage(role: .user, content: question)
        let assistantMessage = ConversationMessage(role: .assistant, content: response.content, citations: response.citedCaptureIDs)
        try await store.addMessage(userMessage)
        try await store.addMessage(assistantMessage)
        return assistantMessage
    }
}
