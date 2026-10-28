import Foundation

/// Topics, period reviews and long-term memory are projections of the daily reviews, which the model
/// writes once per day from the whole day's original text. Nothing here guesses speakers or subjects
/// with patterns, and every projected event keeps the daily review's source IDs and verbatim quotes.
public struct DailyKnowledgeEngine: Sendable {
    public init() {}

    /// Stable key for a topic name: case, spacing and punctuation do not split one matter in two.
    public static func topicKey(_ name: String) -> String { MatterEvidence.key(name) }

    struct Entry: Sendable {
        var summary: DailySummary
        var item: DailySummaryItem
        var knowledge: DailyItemKnowledge
        var sources: [UUID]
    }

    /// Entries whose sources are all still live and not excluded. Deleting a screenshot removes the
    /// entries built from it, so a topic never outlives its evidence.
    func entries(in state: RecallState) -> [Entry] {
        let live = Set(state.correctedForAnalysis().captures
            .filter { !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") }.map(\.id))
        let invalid = Set(state.matterCorrections.filter { $0.kind == .notMine || $0.kind == .inaccurate }.flatMap(\.evidenceIDs))
        return state.dailySummaries.flatMap { summary -> [Entry] in
            summary.items.compactMap { item in
                guard let knowledge = item.knowledge else { return nil }
                let sources = item.evidenceIDs.filter { live.contains($0) && !invalid.contains($0) }
                guard !sources.isEmpty, sources.count == item.evidenceIDs.count else { return nil }
                return Entry(summary: summary, item: item, knowledge: knowledge, sources: sources)
            }
        }
    }

    /// Changes when any structured daily item (or the evidence it depends on) changes.
    public func fingerprint(in state: RecallState) -> String {
        let rows = entries(in: state).map { entry in
            [entry.item.id.uuidString, entry.knowledge.topic ?? "", entry.knowledge.kind.rawValue, entry.knowledge.status,
             entry.item.title, entry.item.detail, String(entry.knowledge.ownedByUser)].joined(separator: "\u{1f}")
        }.sorted()
        return CaptureUnderstandingEngine.digest(rows.joined(separator: "\n"))
    }
    public func hasStructuredReviews(in state: RecallState) -> Bool {
        state.dailySummaries.contains { $0.items.contains { $0.knowledge != nil } }
    }

    static func status(_ value: String) -> WorkEpisodeStatus {
        switch value {
        case "completed": .completed
        case "pending": .pending
        case "inProgress", "progressed": .progressed
        case "blocked": .blocked
        default: .explored
        }
    }

    /// Own matters grouped by topic, each day's item becoming one event. A later day's state replaces
    /// the earlier one in the topic's timeline order; nothing is merged away.
    public func matterFiles(in state: RecallState) -> [MatterFile] {
        var groups: [String: (name: String, events: [MatterEvent])] = [:]
        for entry in entries(in: state) where entry.knowledge.kind == .matter && entry.knowledge.ownedByUser {
            guard let topic = entry.knowledge.topic, !Self.topicKey(topic).isEmpty else { continue }
            let key = "topic:" + Self.topicKey(topic)
            let day = entry.summary.day
            var event = MatterEvent(id: Self.eventID(entry, key: key), title: topic,
                detail: entry.item.detail.isEmpty ? entry.item.title : entry.item.title + "：" + entry.item.detail,
                recordedAt: day, eventAt: nil, status: Self.status(entry.knowledge.status),
                evidenceIDs: entry.sources.sorted { $0.uuidString < $1.uuidString },
                nextAction: entry.item.section.canonical == .actions ? entry.item.title : nil)
            event.sequence = 0
            var current = groups[key] ?? (topic, [])
            // The latest name wins as the display title.
            current.name = topic
            current.events.append(event)
            groups[key] = current
        }
        return groups.map { key, value in
            let ordered = value.events.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
            return MatterFile(id: key, title: value.name, events: ordered)
        }.sorted { $0.latest.date == $1.latest.date ? $0.id < $1.id : $0.latest.date > $1.latest.date }
    }

    /// Material the user read or received. Kept as references: it cannot become a personal fact.
    public func referenceFiles(in state: RecallState) -> [MatterFile] {
        var groups: [String: (name: String, events: [MatterEvent])] = [:]
        for entry in entries(in: state) where entry.knowledge.kind == .reference || !entry.knowledge.ownedByUser
            && entry.knowledge.kind == .matter {
            let name = entry.knowledge.topic ?? entry.item.title
            let key = "reference:" + Self.topicKey(name)
            var event = MatterEvent(id: Self.eventID(entry, key: key), title: name,
                detail: entry.item.detail.isEmpty ? entry.item.title : entry.item.title + "：" + entry.item.detail,
                recordedAt: entry.summary.day, status: .explored, evidenceIDs: entry.sources)
            event.isReference = true
            groups[key, default: (name, [])].events.append(event)
        }
        return groups.map { key, value in
            MatterFile(id: key, title: value.name, events: value.events.sorted { $0.date < $1.date })
        }.sorted { $0.latest.date > $1.latest.date }
    }

    /// Preferences, agreements and people stated by the user, as long-term memory candidates.
    public func personalClaims(in state: RecallState, now: Date = .now) -> [MemoryClaim] {
        let kinds: [DailyItemKind: MemoryClaimKind] = [.preference: .preference, .agreement: .constraint, .person: .person]
        let grouped = Dictionary(grouping: entries(in: state).filter {
            kinds[$0.knowledge.kind] != nil && $0.knowledge.ownedByUser
        }) { entry in kinds[entry.knowledge.kind]!.rawValue + ":" + Self.topicKey(entry.item.title) }
        return grouped.compactMap { key, entries -> MemoryClaim? in
            guard let first = entries.min(by: { $0.summary.day < $1.summary.day }),
                  let last = entries.max(by: { $0.summary.day < $1.summary.day }),
                  let kind = kinds[first.knowledge.kind] else { return nil }
            let evidence = entries.flatMap { entry in
                entry.sources.map { id in
                    MemoryEvidence(captureID: id, fragment: 0, quote: entry.knowledge.quotes.first ?? entry.item.title,
                        speaker: "每日回顾（本人表述）", sourceVersion: WeeklyReviewEngine.sourceVersion(id: id, state: state) ?? "",
                        recordedAt: entry.summary.day, eventAt: nil, sourceApp: nil, sourceBundle: nil)
                }
            }
            let days = Set(entries.map { Calendar.current.startOfDay(for: $0.summary.day) })
            let identifier = MemoryKnowledgeEngine.id("daily:" + key)
            var claim = MemoryClaim(id: identifier, key: identifier.uuidString, subjectID: "user",
                title: first.item.title, content: last.item.detail.isEmpty ? last.item.title : last.item.detail, kind: kind,
                state: days.count >= 2 ? .active : .tentative, scope: .global, scopeID: nil, evidence: evidence,
                dependencies: [], supersedes: [], status: nil, resultStatus: nil, nextAction: nil,
                validFrom: first.summary.day, validUntil: nil, updatedAt: last.summary.day, explicit: false)
            if kind != .person { claim.validUntil = Calendar.current.date(byAdding: .day, value: 180, to: last.summary.day) }
            if let until = claim.validUntil, until <= now { claim.state = .expired }
            return claim
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func eventID(_ entry: Entry, key: String) -> UUID {
        MatterEvidence.eventID(source: entry.summary.id, topic: key + "|" + entry.item.id.uuidString, ordinal: 0)
    }
}
