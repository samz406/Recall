import Foundation

/// An explicit UI restriction is applied before either local or model retrieval.
public struct MemoryQueryScope: Hashable, Sendable {
    public var start: Date?
    public var end: Date?
    public var topicID: String?
    public var recentDays: Int?
    /// Sources of the topic the user actually opened, available before ledger maintenance.
    public var topicEvidenceIDs: Set<UUID>?
    public static let all = MemoryQueryScope()
    public init(start: Date? = nil, end: Date? = nil, topicID: String? = nil, recentDays: Int? = nil, topicEvidenceIDs: Set<UUID>? = nil) {
        self.start = start; self.end = end; self.topicID = topicID; self.recentDays = recentDays
        self.topicEvidenceIDs = topicID == nil ? nil : topicEvidenceIDs
    }
    public var isRestricted: Bool { start != nil || end != nil || topicID != nil || recentDays != nil }
    /// Intersect the requested dates with the selected UI scope before any retrieval tool sees the archive.
    func applying(to original: RecallState, questionRange: ResolvedMemoryTimeRange?) -> RecallState {
        let selected = applying(to: original)
        guard let range = questionRange else { return selected }
        func contains(_ date: Date) -> Bool { date >= range.startDate && date < range.endDate }
        var dated = Self(start: range.startDate, end: range.endDate).applying(to: selected)
        dated.dailySummaries.removeAll { !contains($0.day) }
        // Legacy local reviews are independently dated and never eligible for cloud read tools.
        dated.dailySummaries += selected.dailySummaries.filter { $0.sourceCaptureIDs.isEmpty && contains($0.day) }
        let ids = Set(dated.captures.map(\.id))
        // Ongoing multi-day claims created earlier can still be updated/cited by records in this window;
        // `selected` has already enforced privacy and topic restrictions on the full source set.
        dated.memoryKnowledge.claims = selected.memoryKnowledge.claims.compactMap { claim in
            guard contains(claim.date) else { return nil }
            let inWindow = claim.sourceIDs.filter(ids.contains)
            guard !inWindow.isEmpty else { return nil }
            var copy = claim
            copy.evidence = claim.evidence.filter { ids.contains($0.captureID) }
            return copy.evidence.isEmpty ? nil : copy
        }
        dated.reminders.removeAll { $0.sourceCaptureIDs.isEmpty ? !contains($0.createdAt) : !Set($0.sourceCaptureIDs).isSubset(of: ids) }
        if start == nil, end == nil, recentDays == nil {
            dated.messages = selected.messages
            dated.conversationSummary = selected.conversationSummary
            dated.conversationSummaryCoveredMessageCount = selected.conversationSummaryCoveredMessageCount
        }
        return dated
    }

    public func applying(to original: RecallState) -> RecallState {
        if let days = recentDays {
            let now = Date.now
            let first = Calendar.current.date(byAdding: .day, value: -(max(1, days) - 1), to: Calendar.current.startOfDay(for: now)) ?? now
            return Self(start: first, end: now, topicID: topicID, topicEvidenceIDs: topicEvidenceIDs).applying(to: original)
        }
        guard isRestricted else { return original }
        var state = original
        let topicSources: Set<UUID>? = topicID.map { id in
            Set(original.memoryKnowledge.claims.filter { $0.subjectID == id || ($0.scope == .project && $0.scopeID == id) }.flatMap(\.sourceIDs))
                .union(topicEvidenceIDs ?? [])
                .union(original.topicGroups.filter { $0.id == id }.flatMap { group in
                    original.memoryKnowledge.claims.filter { group.memberIDs.contains($0.subjectID) }.flatMap(\.sourceIDs)
                })
        }
        state.captures = original.captures.filter {
            (start == nil || $0.createdAt >= start!) && (end == nil || $0.createdAt < end!)
                && (topicSources == nil || topicSources!.contains($0.id))
        }
        let ids = Set(state.captures.map(\.id))
        state.dailySummaries = original.dailySummaries.compactMap { $0.scoping(to: ids) }
        state.episodes.removeAll { !Set($0.evidenceIDs).isSubset(of: ids) }
        state.userMemories.removeAll { !Set($0.evidenceIDs).isSubset(of: ids) }
        state.memoryKnowledge.claims.removeAll { $0.sourceIDs.isEmpty || !Set($0.sourceIDs).isSubset(of: ids) }
        state.memoryKnowledge.entities = state.memoryKnowledge.entities.compactMap { entity in
            var copy = entity; copy.sourceIDs = copy.sourceIDs.filter(ids.contains)
            return copy.sourceIDs.isEmpty ? nil : copy
        }
        if start != nil || end != nil {
            state.conversationSummary = nil
            state.messages = []
        } else {
            let filteredMessages = original.messages.filter { $0.citations.isEmpty || Set($0.citations).isSubset(of: ids) }
            state.messages = filteredMessages
            if filteredMessages.count != original.messages.count {
                state.conversationSummary = nil
                state.conversationSummaryCoveredMessageCount = 0
            }
        }
        return state
    }
}

extension DailySummary {
    /// Retains only structured items and ledger entries whose own evidence is completely within `allowedIDs`.
    /// Prevents a single unrelated or excluded screenshot on the same day from wiping out every other item's review.
    func scoping(to allowedIDs: Set<UUID>) -> DailySummary? {
        guard !sourceCaptureIDs.isEmpty else { return nil }
        if Set(sourceCaptureIDs).isSubset(of: allowedIDs) { return self }
        let keptItems = items.filter { !$0.evidenceIDs.isEmpty && Set($0.evidenceIDs).isSubset(of: allowedIDs) }
        let keptLedger = ledger.filter { !$0.evidenceIDs.isEmpty && Set($0.evidenceIDs).isSubset(of: allowedIDs) }
        let keptTodos = todos.filter { !$0.sourceCaptureIDs.isEmpty && Set($0.sourceCaptureIDs).isSubset(of: allowedIDs) }
        guard !keptItems.isEmpty || !keptLedger.isEmpty else { return nil }
        var copy = self
        copy.items = keptItems
        copy.ledger = keptLedger
        copy.todos = keptTodos
        copy.content = DailySummaryItemParser.markdown(from: keptItems)
        copy.briefing = nil
        copy.versions = nil
        copy.sourceCaptureIDs = (keptItems.flatMap(\.evidenceIDs) + keptLedger.flatMap(\.evidenceIDs) + keptTodos.flatMap(\.sourceCaptureIDs)).memoryUnique()
        return copy
    }
}
