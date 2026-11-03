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
        scope: MemoryQueryScope = .all,
        onUserMessageSaved: (@MainActor @Sendable () async -> Void)? = nil,
        onRetrievalWarning: (@MainActor @Sendable () -> Void)? = nil,
        onEvidenceReady: (@MainActor @Sendable (Int) -> Void)? = nil,
        model: (any LLMResponding)? = nil,
        onPartial: (@MainActor @Sendable (String) -> Void)? = nil,
        onStep: (@MainActor @Sendable (String, Int) -> Void)? = nil,
        limits: AskLimits = .standard
    ) async throws -> ConversationMessage {
        try Task.checkCancellation()
        if ChatCommand.parse(question) == .clear {
            let result = try await store.clearConversation()
            await onUserMessageSaved?()
            return result
        }
        let conversation = await store.conversationSnapshot()
        try Task.checkCancellation()
        let originalState = conversation.state
        if ChatCommand.isCommandInput(question) {
            let result = ConversationMessage(role: .system, content: "未识别的命令或参数。输入 / 查看可用命令；清空会话请发送 /clear。")
            try await store.addMessage(result, inConversation: conversation.id)
            await onUserMessageSaved?()
            return result
        }
        let userMessage = userMessage ?? ConversationMessage(role: .user, content: question)
        try await store.addMessage(userMessage, inConversation: conversation.id)
        await onUserMessageSaved?()
        try Task.checkCancellation()
        if let directive = MemoryDirective.parse(question, conversationID: conversation.id) {
            let record = try await store.remember(directive)
            let includesTask = ["解释", "分析", "总结", "写一", "帮我", "告诉", "查一下", "看看", "怎么", "什么", "聊聊"].contains(where: question.contains)
            if directive.scope != .conversation || !includesTask {
            let answer = ConversationMessage(role: .assistant,
                content: "已记住：" + directive.content + "\n适用范围：" + directive.scope.title + "。你可以在‘记忆 → 长期记忆’中修改或停用。",
                citations: [record.id])
            try await store.addMessage(answer, inConversation: conversation.id)
            return answer
            }
        }
        let clock = ContinuousClock()
        let analysisStarted = clock.now
        let textIndex = await store.captureTextIndex()
        let fullState = await store.preparedForChat()
        onStep?("analysis", Self.milliseconds(from: analysisStarted, clock: clock))
        var state = scope.applying(to: fullState)
        state.messages.removeAll { $0.id == userMessage.id }
        if let answer = try await cloudAgentAnswer(
            question: question, conversationID: conversation.id, scope: scope,
            fullState: fullState, state: state, originalState: originalState, textIndex: textIndex,
            model: model, limits: limits, onPartial: onPartial, onStep: onStep, onRetrievalWarning: onRetrievalWarning, onEvidenceReady: onEvidenceReady
        ) { return answer }
        let retrievalStarted = clock.now

        let resolvedQuestion = retrievalText(for: question, history: state.messages)
        let retrievalText: String
        if let days = scope.recentDays, timeRangeResolver.resolve(resolvedQuestion) == nil {
            retrievalText = "最近\(max(1, days))天，" + resolvedQuestion
        } else { retrievalText = resolvedQuestion }
        let timeRange = timeRangeResolver.resolve(retrievalText)
        let intent = MemoryQuestionIntent(question: question)
        let participating = state.captures.filter { capture in
            let participates = state.rules.first(where: { $0.template == capture.eventTemplate })?.participatesInChat ?? true
            return participates && !state.privacy.excludedBundleIdentifiers.contains(capture.sourceBundleIdentifier ?? "")
        }
        let recordsAllowedInChat = participating.filter { capture in
            guard let timeRange else { return true }
            return capture.createdAt >= timeRange.startDate && capture.createdAt <= timeRange.endDate
        }
        let allowedIDs = Set(participating.map(\.id))
        let summaryEvidence = state.dailySummaries.filter {
            ($0.sourceCaptureIDs.isEmpty && state.matterCorrections.isEmpty) || (!$0.sourceCaptureIDs.isEmpty && Set($0.sourceCaptureIDs).isSubset(of: allowedIDs))
        }.map(makeSearchableEvidence)
        let episodeEvidence = state.episodes.filter { !$0.evidenceIDs.isEmpty && Set($0.evidenceIDs).isSubset(of: allowedIDs) }.map(makeSearchableEvidence)
        let durableMemoryEvidence = state.userMemories
            .filter { memory in
                state.memoryKnowledgeSettings.referencesEnabled && !memory.evidenceIDs.isEmpty && Set(memory.evidenceIDs).isSubset(of: allowedIDs) && (memory.status == .confirmed || (memory.status == .proposed && memory.confidence >= 0.75))
            }
            .map(makeSearchableEvidence)
        let searchableEvidence = recordsAllowedInChat + summaryEvidence + episodeEvidence + (timeRange == nil ? durableMemoryEvidence : [])
        // 多日概览靠日期覆盖，不靠“总结本周”这类词去扫每张截图的全文。
        let query = MemorySearchQuery(
            text: timeRange != nil && intent == .overview ? "" : retrievalText,
            startDate: timeRange?.startDate,
            endDate: timeRange?.endDate
        )
        // 多日问题必须先看到范围内的全部候选，再做按天覆盖；若提前截断，
        // 高频的今天记录仍会把较早日期挤出候选集。范围外的截图已经在上面排除。
        let searchLimit = timeRange == nil ? 64 : max(searchableEvidence.count, 1)
        // 截图文字在保存时已经写入词条索引。有索引时只取出命中的记录，不再逐条读全文。
        let results: [MemorySearchResult]
        let indexedIDs: [UUID]
        if let textIndex, !query.text.isEmpty {
            let derived = summaryEvidence + episodeEvidence + (timeRange == nil ? durableMemoryEvidence : [])
            let derivedResults = searchEngine.search(query, in: derived, limit: searchLimit)
            let terms = QuestionTerms.topicTerms(query.text)
            let matchLimit = timeRange == nil ? 80 : 400
            let ids = textIndex.ids(matching: terms, start: timeRange?.startDate, end: timeRange?.endDate, limit: matchLimit)
            let allowedByID = Dictionary(uniqueKeysWithValues: recordsAllowedInChat.map { ($0.id, $0) })
            let candidates = ids.compactMap { allowedByID[$0] }
            let captureResults = searchEngine.search(query, in: candidates, limit: searchLimit)
            var best: [UUID: MemorySearchResult] = [:]
            for result in derivedResults + captureResults {
                if best[result.capture.id]?.score ?? -1 < result.score { best[result.capture.id] = result }
            }
            results = best.values.sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.capture.createdAt > rhs.capture.createdAt : lhs.score > rhs.score
            }.prefix(searchLimit).map { $0 }
            indexedIDs = []
        } else {
            results = searchEngine.search(query, in: searchableEvidence, limit: searchLimit)
            indexedIDs = timeRange == nil ? await store.indexedCaptureIDs(matching: retrievalText, limit: 8) : []
        }
        let indexed = indexedIDs.compactMap { id in recordsAllowedInChat.first(where: { $0.id == id }) }
        var seen: Set<UUID> = []
        let relevantResults = timeRange != nil && intent != .overview
            ? results.filter { !$0.matchedTerms.isEmpty }
            : results
        let ranked = (indexed + relevantResults.map(\.capture)).filter { seen.insert($0.id).inserted }
        let retrieved = if let timeRange {
            selectTemporalEvidence(
                from: ranked,
                limit: min(max(timeRange.requestedDayCount * 2, 8), contextManager.maxEvidenceRecords)
            )
        } else {
            MemoryEvidenceSelector().select(ranked, question: retrievalText, limit: 12)
        }
        let annotated = retrieved.map { annotateForChat($0, originals: originalState) }
        let textMatchIDs: (([String], Date?, Date?) -> [UUID])? = textIndex.map { index in
            { terms, start, end in index.ids(matching: terms, start: start, end: end, limit: 40) }
        }
        var retrieval = MemoryRetrievalEngine().plan(question: retrievalText, state: state, fallback: annotated,
            conversationID: conversation.id, limit: contextManager.maxEvidenceRecords, trustLedger: true, alreadyCorrected: true, textMatchIDs: textMatchIDs)
        onStep?("retrieval", Self.milliseconds(from: retrievalStarted, clock: clock))
        onEvidenceReady?(retrieval.evidence.count)
        if retrieval.needsSemanticLookup, state.privacy.cloudUseEnabled,
           state.llmConfiguration.provider != .localOnly, state.llmConfiguration.hasCredential {
            do {
                let responder = (try await store.modelResponder())
                let ids = try await MemorySemanticLookup().topics(for: retrievalText, in: state, responder: responder, knowledge: state.memoryKnowledge, alreadyCorrected: true)
                if !ids.isEmpty {
                    retrieval = MemoryRetrievalEngine().plan(question: retrievalText, state: state, fallback: annotated,
                        conversationID: conversation.id, limit: contextManager.maxEvidenceRecords, resolvedEntityIDs: ids, trustLedger: true, alreadyCorrected: true, textMatchIDs: textMatchIDs)
                    onEvidenceReady?(retrieval.evidence.count)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { onRetrievalWarning?() }
        }
        let selectedEvidence = retrieval.evidence
        let plan = contextManager.plan(
            history: state.messages,
            existingSummary: state.conversationSummary,
            coveredMessageCount: state.conversationSummaryCoveredMessageCount ?? 0,
            retrievedEvidence: selectedEvidence, question: retrievalText
        )
        if plan.rollingSummary != state.conversationSummary || plan.coveredMessageCount != (state.conversationSummaryCoveredMessageCount ?? 0) {
            try await store.updateConversationSummary(plan.rollingSummary, coveredMessageCount: plan.coveredMessageCount + originalState.messages.count - state.messages.count, inConversation: conversation.id)
        }
        try Task.checkCancellation()
        guard await store.conversationSnapshot().id == conversation.id else { throw CancellationError() }

        // 对时间范围概览问题，当前检索到的时间线是唯一事实来源。
        // 不带入先前助手的结论，避免旧的“没有记忆”回答被模型机械复述。
        let requiresFreshEvidenceTurn = timeRange != nil && !plan.evidence.isEmpty
        let request = LLMRequest(
            question: question,
            context: plan.evidence,
            conversationSummary: requiresFreshEvidenceTurn ? nil : plan.rollingSummary,
            supplementaryContext: retrieval.preferences,
            recentMessages: requiresFreshEvidenceTurn ? [] : plan.recentMessages
        )
        let response: LLMAnswer

        switch state.privacy.cloudUseEnabled ? state.llmConfiguration.provider : .localOnly {
        case .localOnly:
            response = try await ExtractiveMemoryResponder().answer(to: request)
        case .openAICompatible, .anthropicCompatible:
            let beforeCloud = await store.snapshot()
            guard state.privacy.cloudUseEnabled, beforeCloud.privacy.cloudUseEnabled else {
                throw LLMError.serviceError("请先在隐私设置中明确开启云端模型使用。")
            }
            guard beforeCloud.privacy.excludedBundleIdentifiers == state.privacy.excludedBundleIdentifiers,
                  beforeCloud.memoryKnowledgeSettings == state.memoryKnowledgeSettings,
                  Set(state.captures.map(\.id)).isSubset(of: Set(beforeCloud.captures.map(\.id))),
                  beforeCloud.matterCorrections.map(\.id) == state.matterCorrections.map(\.id),
                  SummaryFeedbackLearning.revision(in: beforeCloud) == SummaryFeedbackLearning.revision(in: state),
                  beforeCloud.memoryKnowledge.suppressedKeys == state.memoryKnowledge.suppressedKeys else {
                throw LLMError.serviceError("记忆或隐私设置已更新，请重新提问。")
            }
            guard beforeCloud.llmConfiguration == state.llmConfiguration else { throw CredentialError.unavailable }
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
                supplementaryContext: request.supplementaryContext.map(privacyEngine.redact),
                recentMessages: safeRecentMessages
            )
            let modelStarted = clock.now
            let responder = if let model { model } else { try await store.modelResponder() }
            let cloudAnswer = try await responder.answerCancellably(to: cloudRequest)
            onStep?("model", Self.milliseconds(from: modelStarted, clock: clock))
            // 已传入证据时，不能接受模型仍声称“记忆为空”的幻觉式回答。
            // 此时保留本地可追溯摘要，确保用户至少得到真实的时间线内容。
            response = !safeContext.isEmpty && claimsEvidenceIsEmpty(cloudAnswer.content)
                ? try await ExtractiveMemoryResponder().answer(to: request)
                : cloudAnswer
        }

        let latestState = await store.snapshot()
        guard latestState.llmConfiguration == state.llmConfiguration,
              latestState.matterCorrections.map(\.id) == originalState.matterCorrections.map(\.id),
              SummaryFeedbackLearning.revision(in: latestState) == SummaryFeedbackLearning.revision(in: originalState),
              Set(state.captures.map(\.id)).isSubset(of: Set(latestState.captures.map(\.id))) else {
            throw LLMError.serviceError("记忆已更正或删除，请重新提问以使用最新内容。")
        }
        let usedSourceIDs = Set(plan.evidence.flatMap { retrieval.sourceIDs[$0.id] ?? [$0.id] } + retrieval.preferenceSourceIDs)
        let legacyIDs = Set(state.dailySummaries.filter { $0.sourceCaptureIDs.isEmpty }.map(\.id)).intersection(usedSourceIDs)
        guard legacyIDs.isSubset(of: Set(latestState.dailySummaries.map(\.id))) else { throw LLMError.serviceError("历史回顾已更新，请重新提问。") }
        let currentSources = latestState.analysisCaptures(for: usedSourceIDs)
        let changedSource = state.captures.contains { source in
            guard usedSourceIDs.contains(source.id) else { return false }
            guard let current = currentSources[source.id] else { return true }
            return MemoryKnowledgeEngine.version(of: source, corrections: state.matterCorrections)
                != MemoryKnowledgeEngine.version(of: current, corrections: latestState.matterCorrections)
        }
        let personalBefore = fullState.memoryKnowledge.claims.filter { $0.kind.isPersonal && $0.usable() }
        let personalAfter = latestState.memoryKnowledge.claims.filter { $0.kind.isPersonal && $0.usable() }
        guard !changedSource, state.memoryKnowledgeSettings == latestState.memoryKnowledgeSettings,
              Set(personalBefore.map(\.id)) == Set(personalAfter.map(\.id)),
              state.memoryKnowledge.suppressedKeys == latestState.memoryKnowledge.suppressedKeys,
              MemoryKnowledgeEngine().sourcesUsable(Set(retrieval.preferenceSourceIDs), in: latestState, knowledge: latestState.memoryKnowledge) else {
            throw LLMError.serviceError("记忆或约定已更新，请重新提问以使用最新内容。")
        }
        let formattedContent = ChatResponseFormatter().format(response.content)
        let citations = (response.citedCaptureIDs.flatMap { id in retrieval.sourceIDs[id] ?? [id] } + retrieval.preferenceSourceIDs).memoryUnique()
        let assistantMessage = ConversationMessage(role: .assistant, content: formattedContent, citations: citations)
        try Task.checkCancellation()
        try await store.addMessage(assistantMessage, inConversation: conversation.id)
        return assistantMessage
    }

    private func cloudAgentAnswer(
        question: String,
        conversationID: UUID,
        scope: MemoryQueryScope,
        fullState: RecallState,
        state: RecallState,
        originalState: RecallState,
        textIndex: CaptureTextIndex?,
        model: (any LLMResponding)?,
        limits: AskLimits,
        onPartial: (@MainActor @Sendable (String) -> Void)?,
        onStep: (@MainActor @Sendable (String, Int) -> Void)?,
        onRetrievalWarning: (@MainActor @Sendable () -> Void)?,
        onEvidenceReady: (@MainActor @Sendable (Int) -> Void)?
    ) async throws -> ConversationMessage? {
        let live = await store.snapshot()
        guard live.privacy.cloudUseEnabled, live.llmConfiguration.provider != .localOnly,
              model != nil || live.llmConfiguration.hasCredential else { return nil }
        guard live.privacy.excludedBundleIdentifiers == originalState.privacy.excludedBundleIdentifiers,
              live.memoryKnowledgeSettings == originalState.memoryKnowledgeSettings,
              Set(originalState.captures.map(\.id)).isSubset(of: Set(live.captures.map(\.id))),
              live.matterCorrections.map(\.id) == originalState.matterCorrections.map(\.id),
              SummaryFeedbackLearning.revision(in: live) == SummaryFeedbackLearning.revision(in: originalState),
              live.memoryKnowledge.suppressedKeys == originalState.memoryKnowledge.suppressedKeys else {
            throw LLMError.serviceError("记忆或隐私设置已更新，请重新提问。")
        }
        guard live.llmConfiguration == originalState.llmConfiguration else { throw CredentialError.unavailable }
        let outcome: AskTranscript
        do {
            let responder = if let model { model } else { try await store.modelResponder() }
            outcome = try await AskAgent.answer(
                question: question, state: fullState, scope: scope, textIndex: textIndex, responder: responder,
                limits: limits, onPartial: onPartial, onStep: onStep
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            onRetrievalWarning?()
            return nil
        }
        onEvidenceReady?(outcome.citations.count)
        let latestState = await store.snapshot()
        guard latestState.llmConfiguration == originalState.llmConfiguration,
              latestState.matterCorrections.map(\.id) == originalState.matterCorrections.map(\.id),
              SummaryFeedbackLearning.revision(in: latestState) == SummaryFeedbackLearning.revision(in: originalState),
              Set(state.captures.map(\.id)).isSubset(of: Set(latestState.captures.map(\.id))) else {
            throw LLMError.serviceError("记忆已更正或删除，请重新提问以使用最新内容。")
        }
        let usedSourceIDs = Set(outcome.inspectedSourceIDs)
        let legacyIDs = Set(state.dailySummaries.filter { $0.sourceCaptureIDs.isEmpty }.map(\.id)).intersection(usedSourceIDs)
        guard legacyIDs.isSubset(of: Set(latestState.dailySummaries.map(\.id))) else { throw LLMError.serviceError("历史回顾已更新，请重新提问。") }
        let currentSources = latestState.analysisCaptures(for: usedSourceIDs)
        let changedSource = state.captures.contains { source in
            guard usedSourceIDs.contains(source.id) else { return false }
            guard let current = currentSources[source.id] else { return true }
            return MemoryKnowledgeEngine.version(of: source, corrections: state.matterCorrections)
                != MemoryKnowledgeEngine.version(of: current, corrections: latestState.matterCorrections)
        }
        let personalBefore = fullState.memoryKnowledge.claims.filter { $0.kind.isPersonal && $0.usable() }
        let personalAfter = latestState.memoryKnowledge.claims.filter { $0.kind.isPersonal && $0.usable() }
        guard !changedSource, state.memoryKnowledgeSettings == latestState.memoryKnowledgeSettings,
              Set(personalBefore.map(\.id)) == Set(personalAfter.map(\.id)),
              state.memoryKnowledge.suppressedKeys == latestState.memoryKnowledge.suppressedKeys else {
            throw LLMError.serviceError("记忆或约定已更新，请重新提问以使用最新内容。")
        }
        guard await store.conversationSnapshot().id == conversationID else { throw CancellationError() }
        let message = ConversationMessage(role: .assistant, content: ChatResponseFormatter().format(outcome.content), citations: outcome.citations.memoryUnique())
        try Task.checkCancellation()
        try await store.addMessage(message, inConversation: conversationID)
        return message
    }

    private static func milliseconds(from start: ContinuousClock.Instant, clock: ContinuousClock) -> Int {
        let parts = start.duration(to: clock.now).components
        return Int(truncatingIfNeeded: parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    /// Date and correction notes are for the model. Only the records that will actually be sent are copied.
    private func annotateForChat(_ capture: CaptureRecord, originals: RecallState) -> CaptureRecord {
        guard originals.captures.contains(where: { $0.id == capture.id }) else { return capture }
        var copy = capture
        let originalDate = originals.captures.first { $0.id == capture.id }?.createdAt ?? capture.createdAt
        let explicitDate = originals.matterCorrections.last { $0.kind == .eventDate && $0.evidenceIDs.contains(capture.id) }?.eventAt
        let dateNote = explicitDate.map { "用户确认发生时间：\($0.formatted())" } ?? "实际发生时间未确认，不能把记录时间当作发生时间。"
        let originalText = originals.captures.first { $0.id == capture.id }?.ocrText ?? capture.ocrText
        let correctionNote = SummaryFeedbackLearning.adjusted(capture, in: originals).ocrText != originalText ? "含用户反馈更正；原始截图文字仍保留在时间线。\n" : ""
        copy.ocrText = correctionNote + "记录时间：\(originalDate.formatted())；\(dateNote)\n" + copy.ocrText
        return copy
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
        let governedContent = summary.items.isEmpty ? summary.content : DailySummaryItemParser.markdown(from: summary.items)
        let provenance = summary.sourceCaptureIDs.isEmpty ? "历史总结（未关联原始来源，内容仍需核实）" : "每日总结（派生内容，可查原始来源）"
        let text = [provenance, governedContent, todoText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return CaptureRecord(
            id: summary.id,
            eventTemplate: .dailyReview,
            createdAt: summary.day,
            sourceAppName: "每日总结",
            sourceBundleIdentifier: "im.recall.daily-summary",
            contentHash: "daily-summary-\(summary.id.uuidString)",
            ocrText: text,
            summary: String(governedContent.prefix(300)),
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
