import Foundation

@MainActor
public final class MemoryAssistant {
    private let store: FileMemoryStore
    private let searchEngine: MemorySearchEngine
    private let privacyEngine: PrivacyEngine
    private let contextManager: ConversationContextManager
    private let timeRangeResolver: MemoryTimeRangeResolver

    public init(
        store: FileMemoryStore,
        searchEngine: MemorySearchEngine = MemorySearchEngine(),
        privacyEngine: PrivacyEngine = PrivacyEngine(),
        contextManager: ConversationContextManager = ConversationContextManager(),
        timeRangeResolver: MemoryTimeRangeResolver = MemoryTimeRangeResolver()
    ) {
        self.store = store
        self.searchEngine = searchEngine
        self.privacyEngine = privacyEngine
        self.contextManager = contextManager
        self.timeRangeResolver = timeRangeResolver
    }

    @discardableResult
    public func ask(
        _ question: String,
        userMessage: ConversationMessage? = nil,
        onUserMessageSaved: (@MainActor @Sendable () async -> Void)? = nil
    ) async throws -> ConversationMessage {
        let state = await store.snapshot()
        let userMessage = userMessage ?? ConversationMessage(role: .user, content: question)
        try await store.addMessage(userMessage)
        await onUserMessageSaved?()

        let recordsAllowedInChat = state.captures.filter { capture in
            state.rules.first(where: { $0.template == capture.eventTemplate })?.participatesInChat ?? true
        }
        let retrievalText = retrievalText(for: question, history: state.messages)
        let timeRange = timeRangeResolver.resolve(retrievalText)
        let summaryEvidence = state.dailySummaries.map(makeSearchableEvidence)
        let episodeEvidence = state.episodes.map(makeSearchableEvidence)
        let durableMemoryEvidence = state.userMemories
            .filter { memory in
                memory.status == .confirmed || (memory.status == .proposed && memory.confidence >= 0.75)
            }
            .map(makeSearchableEvidence)
        let searchableEvidence = recordsAllowedInChat + summaryEvidence + episodeEvidence + (timeRange == nil ? durableMemoryEvidence : [])
        let query = MemorySearchQuery(
            text: retrievalText,
            startDate: timeRange?.startDate,
            endDate: timeRange?.endDate
        )
        // 多日问题必须先看到范围内的全部候选，再做按天覆盖；若提前截断，
        // 高频的今天记录仍会把较早日期挤出候选集。
        let searchLimit = timeRange == nil ? 8 : max(searchableEvidence.count, 1)
        let results = searchEngine.search(query, in: searchableEvidence, limit: searchLimit)
        let indexedIDs = timeRange == nil ? await store.indexedCaptureIDs(matching: retrievalText, limit: 8) : []
        let indexed = indexedIDs.compactMap { id in recordsAllowedInChat.first(where: { $0.id == id }) }
        var seen: Set<UUID> = []
        let ranked = (indexed + results.map(\.capture)).filter { seen.insert($0.id).inserted }
        let retrieved = if let timeRange {
            selectTemporalEvidence(
                from: ranked,
                limit: min(max(timeRange.requestedDayCount * 2, 8), contextManager.maxEvidenceRecords)
            )
        } else {
            Array(ranked.prefix(8))
        }
        let plan = contextManager.plan(
            history: state.messages,
            existingSummary: state.conversationSummary,
            coveredMessageCount: state.conversationSummaryCoveredMessageCount ?? 0,
            retrievedEvidence: retrieved
        )
        if plan.rollingSummary != state.conversationSummary || plan.coveredMessageCount != (state.conversationSummaryCoveredMessageCount ?? 0) {
            try await store.updateConversationSummary(plan.rollingSummary, coveredMessageCount: plan.coveredMessageCount)
        }

        // 对时间范围概览问题，当前检索到的时间线是唯一事实来源。
        // 不带入先前助手的结论，避免旧的“没有记忆”回答被模型机械复述。
        let requiresFreshEvidenceTurn = timeRange != nil && !plan.evidence.isEmpty
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

        let formattedContent = ChatResponseFormatter().format(response.content)
        let assistantMessage = ConversationMessage(role: .assistant, content: formattedContent, citations: response.citedCaptureIDs)
        try await store.addMessage(assistantMessage)
        return assistantMessage
    }

    private func retrievalText(for question: String, history: [ConversationMessage]) -> String {
        let followUpMarkers = ["之前", "刚才", "上面", "前面", "继续", "这个", "那个", "它", "他", "她"]
        guard followUpMarkers.contains(where: question.contains),
              let previousQuestion = history.last(where: { $0.role == .user })?.content else {
            return question
        }
        return "\(previousQuestion) \(question)"
    }

    private func makeSearchableEvidence(from summary: DailySummary) -> CaptureRecord {
        let todoText = summary.todos.map { "\($0.title)：\($0.detail)" }.joined(separator: "\n")
        let text = [summary.content, todoText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return CaptureRecord(
            id: summary.id,
            eventTemplate: .dailyReview,
            createdAt: summary.day,
            sourceAppName: "每日总结",
            sourceBundleIdentifier: "im.recall.daily-summary",
            contentHash: "daily-summary-\(summary.id.uuidString)",
            ocrText: text,
            summary: String(summary.content.prefix(300)),
            tags: ["每日总结"]
        )
    }

    private func makeSearchableEvidence(from episode: WorkEpisode) -> CaptureRecord {
        let text = [
            "项目：\(episode.projectName)",
            "事项：\(episode.title)",
            "目标：\(episode.intent)",
            "行动：\(episode.action)",
            episode.outcome.map { "结果：\($0)" },
            episode.nextAction.map { "下一步：\($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
        return CaptureRecord(
            id: episode.id,
            eventTemplate: .taskTransition,
            createdAt: episode.startedAt,
            sourceAppName: "工作片段",
            sourceBundleIdentifier: "im.recall.work-episode",
            contentHash: "work-episode-\(episode.id.uuidString)",
            ocrText: text,
            summary: episode.title,
            tags: [episode.projectName, episode.status.rawValue]
        )
    }

    private func makeSearchableEvidence(from memory: UserMemory) -> CaptureRecord {
        CaptureRecord(
            id: memory.id,
            eventTemplate: .manualMoment,
            createdAt: memory.updatedAt,
            sourceAppName: "长期记忆",
            sourceBundleIdentifier: "im.recall.user-memory",
            contentHash: "user-memory-\(memory.id.uuidString)",
            ocrText: "\(memory.kind.title)：\(memory.content)\n置信度：\(Int(memory.confidence * 100))%",
            summary: memory.content,
            tags: [memory.kind.title]
        )
    }

    /// 多日概览先保证日期覆盖：每个有记录的日期优先取每日总结，没有总结才取原始记录；
    /// 剩余名额再按检索得分补充原始证据，避免最近一天独占整个上下文。
    private func selectTemporalEvidence(
        from ranked: [CaptureRecord],
        limit: Int,
        calendar: Calendar = .current
    ) -> [CaptureRecord] {
        guard limit > 0 else { return [] }
        let grouped = Dictionary(grouping: ranked) { calendar.startOfDay(for: $0.createdAt) }
        let availableDays = grouped.keys.sorted(by: >)
        let coveredDays = evenlySpacedDays(from: availableDays, limit: limit)
        var selected: [CaptureRecord] = []
        var selectedIDs: Set<UUID> = []

        for day in coveredDays {
            let records = (grouped[day] ?? []).sorted { left, right in
                if left.eventTemplate == .dailyReview, right.eventTemplate != .dailyReview { return true }
                if left.eventTemplate != .dailyReview, right.eventTemplate == .dailyReview { return false }
                return left.createdAt > right.createdAt
            }
            if let anchor = records.first, selectedIDs.insert(anchor.id).inserted {
                selected.append(anchor)
            }
        }
        for record in ranked where selected.count < limit {
            if selectedIDs.insert(record.id).inserted { selected.append(record) }
        }
        return selected
    }

    private func evenlySpacedDays(from days: [Date], limit: Int) -> [Date] {
        guard days.count > limit, limit > 1 else { return Array(days.prefix(limit)) }
        return (0..<limit).map { index in
            let position = Double(index) * Double(days.count - 1) / Double(limit - 1)
            return days[Int(position.rounded())]
        }
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

}
