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

    /// Whether the saved ledger still matches the captures and daily reviews it was derived from.
    /// A stored stamp answers this without re-encoding every screenshot. Ledgers saved before the stamp
    /// fall back to the per-capture version check once, then the stamp is recorded.
    public func isMemoryLedgerCurrent() -> Bool {
        let knowledge = state.memoryKnowledge
        guard knowledge.updatedAt != nil, knowledge.organizationVersion == MemoryKnowledgeEngine.organizationVersion else { return false }
        let stamp = MemoryKnowledgeEngine.inputStamp(for: state)
        if knowledge.ledgerInputStamp == stamp { return true }
        guard knowledge.ledgerInputStamp == nil else { return false }
        guard knowledge.dailyFingerprint == DailyKnowledgeEngine().fingerprint(in: state.correctedForAnalysis()) else { return false }
        var safe = state.correctedForAnalysis()
        safe.captures.removeAll { state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") }
        guard safe.captures.count == knowledge.sourceVersions.count else { return false }
        return safe.captures.allSatisfy { knowledge.sourceVersions[$0.id.uuidString] == MemoryKnowledgeEngine.version(of: $0, corrections: state.matterCorrections) }
    }

    /// Chat only needs the ledger to be current. Reconciling scans every capture, so it runs when something changed.
    public func organizeMemoryIfNeeded() throws {
        let stamp = MemoryKnowledgeEngine.inputStamp(for: state)
        let knowledge = state.memoryKnowledge
        if knowledge.updatedAt != nil, knowledge.organizationVersion == MemoryKnowledgeEngine.organizationVersion, knowledge.ledgerInputStamp == stamp { return }
        if knowledge.ledgerInputStamp == nil, isMemoryLedgerCurrent() {
            state.memoryKnowledge.ledgerInputStamp = stamp
            try persist()
            return
        }
        try organizeMemory()
    }

    public func updateMemoryKnowledgeSettings(_ settings: MemoryKnowledgeSettings) throws {
        let previous = state
        do { state.memoryKnowledgeSettings = settings; try persistReviewState(indexChanged: true) }
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
            // An explicit personal update does not require re-reading unrelated OCR or
            // rebuilding factual history. Reconcile the personal evidence slice only.
            let personalIDs = Set(state.memoryKnowledge.claims.filter { $0.kind.isPersonal }.flatMap(\.sourceIDs))
            var input = state
            input.captures = state.captures.filter { $0.memoryDirective != nil || personalIDs.contains($0.id) }
            let personal = MemoryKnowledgeEngine().reconcile(input, force: true, now: now)
            state.memoryKnowledge.claims = state.memoryKnowledge.claims.filter { !$0.kind.isPersonal } + personal.claims.filter { $0.kind.isPersonal }
            let existingEntities = Set(state.memoryKnowledge.entities.map(\.id))
            state.memoryKnowledge.entities += personal.entities.filter { !existingEntities.contains($0.id) }
            state.memoryKnowledge.sourceVersions[record.id.uuidString] = MemoryKnowledgeEngine.version(of: record, corrections: state.matterCorrections)
            state.memoryKnowledge.updatedAt = now
            if state.captures.count == input.captures.count { state.memoryKnowledge.organizationVersion = MemoryKnowledgeEngine.organizationVersion }
            state.memoryKnowledge.ledgerInputStamp = nil
            state.conversationSummary = nil
            state.conversationSummaryCoveredMessageCount = state.messages.count
            try persistReviewState(indexChanged: true)
        } catch { state = previous; throw error }
        return record
    }

    public func retireMemory(id: UUID, now: Date = .now) throws {
        guard let claim = state.memoryKnowledge.claims.first(where: { $0.id == id }) else { return }
        let previous = state
        do {
            state.memoryKnowledge.suppressedKeys.append(claim.key)
            if let index = state.memoryKnowledge.claims.firstIndex(where: { $0.id == id }) {
                state.memoryKnowledge.claims[index].state = .retracted
            }
            state.conversationSummary = nil
            state.messages.removeAll { $0.role == .assistant && !Set($0.citations).isDisjoint(with: claim.sourceIDs) }
            try persistReviewState(indexChanged: true)
        } catch { state = previous; throw error }
    }

    public func correctMemory(id: UUID, content: String, scope: MemoryScope, scopeID: String? = nil, validUntil: Date? = nil) throws {
        guard let claim = state.memoryKnowledge.claims.first(where: { $0.id == id }) else { return }
        let previous = state
        let oldDirective = state.captures.first { claim.sourceIDs.contains($0.id) }?.memoryDirective
        do {
            state.memoryKnowledge.suppressedKeys.append(claim.key)
            if let index = state.memoryKnowledge.claims.firstIndex(where: { $0.id == id }) { state.memoryKnowledge.claims[index].state = .retracted }
            state.messages.removeAll { $0.role == .assistant && !Set($0.citations).isDisjoint(with: claim.sourceIDs) }
            state.conversationSummary = nil
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
        state.applyReconciledKnowledge(knowledge)
    }

    public func finishScreenshotCleanup(paths: [String]) throws {
        let finished = Set(paths)
        state.memoryKnowledge.pendingScreenshotDeletions.removeAll { finished.contains($0) }
        try persist()
    }
}

extension RecallState {
    mutating func applyReconciledKnowledge(_ knowledge: MemoryKnowledge) {
        let withdrawn = MemoryKnowledgeEngine.withdrawnSourceIDs(from: memoryKnowledge, to: knowledge)
        memoryKnowledge = knowledge
        // The ledger is derived from the reviews. A change in the ledger alone doesn't invalidate their sources.
        invalidateMemoryOutputs(sourceIDs: withdrawn, preservingDailyReviews: true)
    }

    mutating func invalidateMemoryOutputs(sourceIDs: Set<UUID>, preservingDailyReviews: Bool = false) {
        guard !sourceIDs.isEmpty else { return }
        if !preservingDailyReviews {
            dailyReviewCheckpoints.removeAll { !Set($0.sourceVersions.keys).isDisjoint(with: sourceIDs) }
            dailySummaries.removeAll { !Set($0.sourceCaptureIDs).isDisjoint(with: sourceIDs) }
        }
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


extension FileMemoryStore {
    /// Cancels an explicit remember operation without deleting its source or factual history.
    public func undoRemembering(sourceID: UUID) throws {
        guard let source = state.captures.first(where: { $0.id == sourceID }), let directive = source.memoryDirective,
              let claim = state.memoryKnowledge.claims.first(where: { $0.usable() && $0.sourceIDs.contains(sourceID) && $0.kind.isPersonal }) else { return }
        let before = state
        do {
            state.memoryKnowledge.suppressedKeys.append(claim.key)
            if let i = state.memoryKnowledge.claims.firstIndex(where: { $0.id == claim.id }) { state.memoryKnowledge.claims[i].state = .retracted }
            let prior = state.captures.filter { record in
                guard record.createdAt < source.createdAt, let saved = record.memoryDirective else { return false }
                return saved.key == directive.key && saved.scope == directive.scope && saved.scopeID == directive.scopeID
            }.max { $0.createdAt < $1.createdAt }
            if let previous = prior?.memoryDirective { _ = try remember(previous) }
            else { try persistReviewState(indexChanged: true) }
        } catch { state = before; throw error }
    }

    public func applyMemoryCommand(_ command: MemoryManagementCommand) throws -> String {
        let matches = command.matches(in: state)
        guard matches.count == 1, let target = matches.first else {
            return matches.isEmpty ? "没有找到这条有效记忆。可以在‘记忆 → 关于我’查看并修改。" : "找到多条相关记忆，请写出要修改的完整内容：\n" + matches.prefix(5).map { "- " + $0.content }.joined(separator: "\n")
        }
        switch command.action {
        case .forget:
            try retireMemory(id: target.id)
            return "已不再记住：" + target.content + "\n后续不再参考这条记忆。"
        case .pause, .resume:
            var settings = state.memoryKnowledgeSettings
            var disabled = Set(settings.disabledClaimKeys ?? [])
            if case .pause = command.action { disabled.insert(target.key) } else { disabled.remove(target.key) }
            settings.disabledClaimKeys = Array(disabled).sorted()
            let before = state
            do { state.memoryKnowledgeSettings = settings; state.conversationSummary = nil; try persistReviewState() }
            catch { state = before; throw error }
            return (disabled.contains(target.key) ? "已暂停参考：" : "已恢复参考：") + target.content
        case .replace(let content):
            try correctMemory(id: target.id, content: content, scope: target.scope, scopeID: target.scopeID, validUntil: target.validUntil)
            return "已更新记忆：" + content + "\n适用范围：" + target.scope.title
        }
    }
}
