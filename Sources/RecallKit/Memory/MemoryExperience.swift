import Foundation

/// Reading a topic never requires a model call. Only saved, evidence-backed text is used here.
public struct TopicReading: Sendable {
    public let overview: String
    public let records: [MatterEvent]
    public let points: [TopicReviewPoint]
    public let hasUpdatedSummary: Bool

    public static func fingerprint(_ file: MatterFile) -> String {
        CaptureUnderstandingEngine.digest(file.events.map { $0.id.uuidString + $0.detail + $0.status.rawValue + $0.evidenceIDs.map(\.uuidString).sorted().joined() }.joined(separator: "\n"))
    }
    public init(file: MatterFile, review: TopicModelReview? = nil) {
        var seen = Set<String>()
        records = file.events.reversed().filter { event in
            let text = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && seen.insert(text).inserted
        }
        let usable = review.flatMap { $0.id == file.id ? $0 : nil }
        let resolvedOverview = usable?.overview.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? file.resumeText
        overview = resolvedOverview
        if let usable { points = usable.points }
        else {
            // Select actual milestones; no generated explanations or guessed decisions.
            var previous: WorkEpisodeStatus?
            var milestones: [MatterEvent] = []
            for event in file.events.dropLast() {
                if milestones.isEmpty || previous != event.status { milestones.append(event) }
                previous = event.status
            }
            points = milestones.suffix(3).filter { $0.detail != resolvedOverview }.map { event in
                TopicReviewPoint(title: RecallLocalization.both("记录于 ", "Recorded ") + event.date.formatted(date: .abbreviated, time: .omitted),
                    detail: event.detail, section: "progress", sourceIDs: event.evidenceIDs)
            }
        }
        hasUpdatedSummary = usable.map { $0.inputFingerprint != nil && Set($0.sourceVersions.keys) == Set(file.evidenceIDs) } ?? false
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Explicit user commands only. Ambiguous names are presented for clarification, never mass-edited.
public struct MemoryManagementCommand: Sendable {
    public enum Action: Sendable { case forget, pause, resume, replace(String) }
    public var action: Action
    public var target: String
    public static func parse(_ input: String) -> MemoryManagementCommand? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("请") { text = String(text.dropFirst()) }
        for (prefix, action) in [("不再记住", Action.forget), ("忘记", .forget), ("暂停参考", .pause), ("恢复参考", .resume)] where text.hasPrefix(prefix) {
            let value = String(text.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "：:，, \"“”‘’。"))
            guard !value.isEmpty, !value.contains("？"), !value.contains("?"), value.count <= 800 else { return nil }
            return Self(action: action, target: value)
        }
        for prefix in ["修改记忆：", "修改记忆:", "更新记忆：", "更新记忆:"] where text.hasPrefix(prefix) {
            let body = String(text.dropFirst(prefix.count))
            let parts = body.components(separatedBy: "改为")
            guard parts.count == 2 else { return nil }
            let values = parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"“”‘’")) }
            guard values.allSatisfy({ !$0.isEmpty && $0.count <= 800 }) else { return nil }
            return Self(action: .replace(values[1]), target: values[0])
        }
        return nil
    }
    public func matches(in state: RecallState) -> [MemoryClaim] {
        let values = state.memoryKnowledge.claims.filter { MemoryLibraryCategory.all.includes($0.kind) && $0.usable() }
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = values.filter { $0.id.uuidString == target || $0.content == target || $0.title == target }
        if !exact.isEmpty { return exact }
        return values.filter { $0.content.localizedCaseInsensitiveContains(target) || $0.title.localizedCaseInsensitiveContains(target) }
    }
}

public enum PersonalMemoryContext {
    public static func text(in state: RecallState, question: String, topicIDs: Set<String> = [], conversationID: UUID? = nil) -> String {
        let allowed = Set(EvidenceAccess.records(state).map(\.id))
        let claims = state.memoryKnowledge.claims.filter {
            $0.kind.isPersonal && $0.usable() && state.memoryKnowledgeSettings.references($0)
                && !$0.sourceIDs.isEmpty && Set($0.sourceIDs).isSubset(of: allowed)
        }
        return MemoryRetrievalEngine().preferenceContext(question: question, claims: claims, conversationID: conversationID, entities: topicIDs) ?? ""
    }
}
