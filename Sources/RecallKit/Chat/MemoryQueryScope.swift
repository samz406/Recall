import Foundation

/// An explicit UI restriction is applied before either local or model retrieval.
public struct MemoryQueryScope: Hashable, Sendable {
    public var start: Date?
    public var end: Date?
    public var topicID: String?
    public static let all = MemoryQueryScope()
    public init(start: Date? = nil, end: Date? = nil, topicID: String? = nil) {
        self.start = start; self.end = end; self.topicID = topicID
    }
    public var isRestricted: Bool { start != nil || end != nil || topicID != nil }
    public func applying(to original: RecallState) -> RecallState {
        guard isRestricted else { return original }
        var state = original
        let topicSources: Set<UUID>? = topicID.map { id in
            Set(original.memoryKnowledge.claims.filter { $0.subjectID == id }.flatMap(\.sourceIDs))
                .union(original.topicGroups.filter { $0.id == id }.flatMap { group in
                    original.memoryKnowledge.claims.filter { group.memberIDs.contains($0.subjectID) }.flatMap(\.sourceIDs)
                })
        }
        state.captures = original.captures.filter {
            (start == nil || $0.createdAt >= start!) && (end == nil || $0.createdAt < end!)
                && (topicSources == nil || topicSources!.contains($0.id))
        }
        let ids = Set(state.captures.map(\.id))
        state.dailySummaries.removeAll { $0.sourceCaptureIDs.isEmpty || !Set($0.sourceCaptureIDs).isSubset(of: ids) }
        state.episodes.removeAll { !Set($0.evidenceIDs).isSubset(of: ids) }
        state.userMemories.removeAll { !Set($0.evidenceIDs).isSubset(of: ids) }
        state.memoryKnowledge.claims.removeAll { $0.sourceIDs.isEmpty || !Set($0.sourceIDs).isSubset(of: ids) }
        state.conversationSummary = nil
        state.messages = []
        return state
    }
}
