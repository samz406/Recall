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
        let query = searchQuery(for: question)
        let results = searchEngine.search(query, in: recordsAllowedInChat)
        let indexedIDs = isTemporalOverviewQuestion(question) ? [] : await store.indexedCaptureIDs(matching: question, limit: 8)
        let indexed = indexedIDs.compactMap { id in recordsAllowedInChat.first(where: { $0.id == id }) }
        var seen: Set<UUID> = []
        let retrieved = (indexed + results.map(\.capture)).filter { seen.insert($0.id).inserted }.prefix(8).map { $0 }
        let plan = contextManager.plan(
            history: state.messages,
            existingSummary: state.conversationSummary,
            coveredMessageCount: state.conversationSummaryCoveredMessageCount ?? 0,
            retrievedEvidence: retrieved
        )
        if plan.rollingSummary != state.conversationSummary || plan.coveredMessageCount != (state.conversationSummaryCoveredMessageCount ?? 0) {
            try await store.updateConversationSummary(plan.rollingSummary, coveredMessageCount: plan.coveredMessageCount)
        }

        // 对“今天/昨天”概览问题，当前检索到的时间线是唯一事实来源。
        // 不带入先前助手的结论，避免旧的“没有记忆”回答被模型机械复述。
        let requiresFreshEvidenceTurn = isTemporalOverviewQuestion(question) && !plan.evidence.isEmpty
        let request = LLMRequest(
            question: question,
            context: plan.evidence,
            conversationSummary: requiresFreshEvidenceTurn ? nil : plan.rollingSummary,
            recentMessages: requiresFreshEvidenceTurn ? [] : plan.recentMessages
        )
        let response: LLMAnswer

        switch state.llmConfiguration.provider {
        case .localOnly:
            response = try await ExtractiveMemoryResponder().answer(to: request)
        case .openAICompatible, .anthropicCompatible:
            guard state.privacy.cloudUseEnabled else {
                throw LLMError.serviceError("请先在隐私设置中明确开启云端模型使用。")
            }
            let key = state.llmConfiguration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw LLMError.missingAPIKey }
            let safeContext = privacyEngine.cloudContext(from: request.context, settings: state.privacy)
            let safeSummary = request.conversationSummary.map(privacyEngine.redact)
            let safeRecentMessages = request.recentMessages.map { message in
                var copy = message
                copy.content = privacyEngine.redact(copy.content)
                return copy
            }
            let cloudRequest = LLMRequest(
                question: question,
                context: safeContext,
                conversationSummary: safeSummary,
                recentMessages: safeRecentMessages
            )
            let cloudAnswer = try await CompatibleLLM(configuration: state.llmConfiguration, apiKey: key).answer(to: cloudRequest)
            // 已传入证据时，不能接受模型仍声称“记忆为空”的幻觉式回答。
            // 此时保留本地可追溯摘要，确保用户至少得到真实的时间线内容。
            response = !safeContext.isEmpty && claimsEvidenceIsEmpty(cloudAnswer.content)
                ? try await ExtractiveMemoryResponder().answer(to: request)
                : cloudAnswer
        }

        let userMessage = ConversationMessage(role: .user, content: question)
        let formattedContent = ChatResponseFormatter().format(response.content)
        let assistantMessage = ConversationMessage(role: .assistant, content: formattedContent, citations: response.citedCaptureIDs)
        try await store.addMessage(userMessage)
        try await store.addMessage(assistantMessage)
        return assistantMessage
    }

    private func claimsEvidenceIsEmpty(_ answer: String) -> Bool {
        let normalized = answer.replacingOccurrences(of: " ", with: "").lowercased()
        let emptyEvidencePhrases = [
            "记忆证据为空", "没有可用的记忆", "没有任何可用的记忆",
            "没有可用记忆", "没有相关的记忆", "没有相关记忆",
            "没有在本地记忆中找到", "无法回答这个问题"
        ]
        return emptyEvidencePhrases.contains { normalized.contains($0) }
    }

    /// 将常见的自然语言日期范围转换为确定性本地过滤条件。
    /// 这让“今天做什么”即便未包含记录正文中的关键词，也能汇总当天记忆。
    private func searchQuery(for question: String, now: Date = .now) -> MemorySearchQuery {
        let normalized = question.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let calendar = Calendar.current

        if isTodayOverviewQuestion(normalized),
           let interval = calendar.dateInterval(of: .day, for: now) {
            return MemorySearchQuery(text: question, startDate: interval.start, endDate: interval.end)
        }

        if isYesterdayOverviewQuestion(normalized),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           let interval = calendar.dateInterval(of: .day, for: yesterday) {
            return MemorySearchQuery(text: question, startDate: interval.start, endDate: interval.end)
        }

        return MemorySearchQuery(text: question)
    }

    private func isTemporalOverviewQuestion(_ question: String) -> Bool {
        let normalized = question.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return isTodayOverviewQuestion(normalized) || isYesterdayOverviewQuestion(normalized)
    }

    private func isTodayOverviewQuestion(_ normalizedQuestion: String) -> Bool {
        normalizedQuestion.contains("今天") || normalizedQuestion.contains("今日") || normalizedQuestion.localizedCaseInsensitiveContains("today")
    }

    private func isYesterdayOverviewQuestion(_ normalizedQuestion: String) -> Bool {
        normalizedQuestion.contains("昨天") || normalizedQuestion.contains("昨日") || normalizedQuestion.localizedCaseInsensitiveContains("yesterday")
    }
}
