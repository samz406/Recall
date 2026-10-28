import Foundation

extension FileMemoryStore {
    public func organizeMemory(force: Bool = false, now: Date = .now) throws {
        let previous = state
        do {
            finishStartupMaintenanceIfNeeded()
            finishPendingDailyReviewMaintenance()
            applyKnowledge(MemoryKnowledgeEngine().reconcile(state, force: force, now: now))
            try persist()
            markStartupMaintenanceComplete()
        } catch { state = previous; throw error }
    }

    public func updateMemoryKnowledgeSettings(_ settings: MemoryKnowledgeSettings) throws {
        let previous = state
        do { state.memoryKnowledgeSettings = settings; try persist() }
        catch { state = previous; throw error }
    }

    @discardableResult
    public func remember(_ directive: MemoryDirective, now: Date = .now) throws -> CaptureRecord {
        let previous = state
        guard !directive.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              directive.content.count <= 800 else { throw LLMError.serviceError("请输入 1–800 字的具体约定。") }
        guard directive.scope != .project || directive.scopeID?.isEmpty == false else { throw LLMError.serviceError("请选择这条记忆适用的主题。") }
        guard directive.scope != .conversation || directive.scopeID?.isEmpty == false else { throw LLMError.serviceError("本次约定需要有效的会话。") }
        guard directive.validUntil == nil || directive.validUntil! > now else { throw LLMError.serviceError("有效期必须晚于当前时间。") }
        let record = CaptureRecord(eventTemplate: .manualMoment, createdAt: now,
            sourceAppName: "记忆约定", sourceBundleIdentifier: "im.recall.app", contentHash: UUID().uuidString,
            ocrText: directive.content, textOrigin: .userInput, memoryDirective: directive)
        do {
            state.captures.insert(record, at: 0)
            var input = state
            if !state.memoryKnowledgeSettings.automaticOrganization {
                let knownIDs = Set(state.memoryKnowledge.sourceVersions.keys).union([record.id.uuidString])
                input.captures = input.captures.filter { knownIDs.contains($0.id.uuidString) }
            }
            applyKnowledge(MemoryKnowledgeEngine().reconcile(input, force: true, now: now))
            state.conversationSummary = nil
            state.conversationSummaryCoveredMessageCount = state.messages.count
            try persist()
        } catch { state = previous; throw error }
        return record
    }

    public func retireMemory(id: UUID, now: Date = .now) throws {
        guard let claim = state.memoryKnowledge.claims.first(where: { $0.id == id }) else { return }
        let previous = state
        do {
            state.memoryKnowledge.suppressedKeys.append(claim.key)
            invalidateMemoryOutputs(sourceIDs: Set(claim.sourceIDs))
            applyKnowledge(MemoryKnowledgeEngine().reconcile(state, force: true, now: now))
            try persist()
        } catch { state = previous; throw error }
    }

    public func correctMemory(id: UUID, content: String, scope: MemoryScope, scopeID: String? = nil, validUntil: Date? = nil) throws {
        guard let claim = state.memoryKnowledge.claims.first(where: { $0.id == id }) else { return }
        let previous = state
        let oldDirective = state.captures.first { claim.sourceIDs.contains($0.id) }?.memoryDirective
        do {
            state.memoryKnowledge.suppressedKeys.append(claim.key)
            invalidateMemoryOutputs(sourceIDs: Set(claim.sourceIDs))
            var directive = MemoryDirective(content: content, key: oldDirective?.key ?? claim.key,
                kind: claim.kind, scope: scope, scopeID: scopeID, validUntil: validUntil)
            directive.scopeExplicitlySet = true
            _ = try remember(directive)
        } catch { state = previous; throw error }
    }

    public func updateMemoryAliases(entityID: String, aliases: [String]) throws {
        guard let index = state.memoryKnowledge.entities.firstIndex(where: { $0.id == entityID }) else { return }
        let previous = state
        let safe = aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { (2...60).contains($0.count) }.memoryUnique()
        state.memoryKnowledge.entities[index].aliases = Array(safe.prefix(12))
        do { try persist() } catch { state = previous; throw error }
    }

    /// Retract every materialized output that used a changed statement; original sources remain available.
    func invalidateMemoryOutputs(sourceIDs: Set<UUID>) {
        state.invalidateMemoryOutputs(sourceIDs: sourceIDs)
    }

    func applyKnowledge(_ knowledge: MemoryKnowledge) {
        let changedSources = MemoryKnowledgeEngine.withdrawnSourceIDs(from: state.memoryKnowledge, to: knowledge)
        state.memoryKnowledge = knowledge
        invalidateMemoryOutputs(sourceIDs: changedSources)
    }

    public func finishScreenshotCleanup(paths: [String]) throws {
        let finished = Set(paths)
        state.memoryKnowledge.pendingScreenshotDeletions.removeAll { finished.contains($0) }
        try persist()
    }
}

extension RecallState {
    mutating func invalidateMemoryOutputs(sourceIDs: Set<UUID>) {
        dailyReviewCheckpoints.removeAll { !Set($0.sourceVersions.keys).isDisjoint(with: sourceIDs) }
        guard !sourceIDs.isEmpty else { return }
        dailySummaries.removeAll { !Set($0.sourceCaptureIDs).isDisjoint(with: sourceIDs) }
        topicReviews.removeAll { !Set($0.sourceVersions.keys).isDisjoint(with: sourceIDs) }
        messages.removeAll { $0.role == .assistant && !Set($0.citations).isDisjoint(with: sourceIDs) }
        episodes.removeAll { !Set($0.evidenceIDs).isDisjoint(with: sourceIDs) }
        projects.removeAll { !Set($0.evidenceIDs).isDisjoint(with: sourceIDs) }
        userMemories.removeAll { !Set($0.evidenceIDs).isDisjoint(with: sourceIDs) }
        insights.removeAll { !Set($0.evidenceIDs).isDisjoint(with: sourceIDs) }
        learnedRoutines.removeAll { !Set($0.evidenceIDs).isDisjoint(with: sourceIDs) }
        for i in weeklyReports.indices where !weeklyReports[i].sourceIDs.isDisjoint(with: sourceIDs) {
            weeklyReports[i].invalidate()
        }
        conversationSummary = nil
        conversationSummaryCoveredMessageCount = messages.count
    }
}
