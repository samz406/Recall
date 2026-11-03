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

    /// Days that already have a structured review. Other days keep the older observed-file path.
    public func structuredDays(in state: RecallState, calendar: Calendar = .current) -> Set<Date> {
        Set(state.dailySummaries.filter { summary in
            !summary.ledger.isEmpty || summary.items.contains { $0.knowledge != nil }
        }.map { calendar.startOfDay(for: $0.day) })
    }

    /// An entry stays while at least one cited screenshot is still valid. Deleted or corrected
    /// screenshots are removed from its evidence. If the only first-person quote is gone, the entry
    /// is kept as a clue (not the user's own matter) instead of disappearing.
    func entries(in state: RecallState) -> [Entry] {
        let captures = state.correctedForAnalysis().captures
            .filter { !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") }
        let live = Set(captures.map(\.id))
        let recordedAt = Dictionary(uniqueKeysWithValues: captures.map { ($0.id, $0.createdAt) })
        let invalid = Set(state.matterCorrections.filter { $0.kind == .notMine || $0.kind == .inaccurate }.flatMap(\.evidenceIDs))
        return state.dailySummaries.flatMap { summary -> [Entry] in
            if !summary.ledger.isEmpty {
                return summary.ledger.compactMap { row in
                    makeEntry(summary: summary, id: row.id, section: row.section, title: row.title, detail: row.detail,
                        topic: row.topic, kind: row.kind, status: row.status, owned: row.ownedByUser, category: row.category,
                        quotes: row.quotes, evidenceIDs: row.evidenceIDs, live: live, invalid: invalid, recordedAt: recordedAt)
                }
            }
            return summary.items.compactMap { item in
                guard let knowledge = item.knowledge else { return nil }
                let quotes = knowledge.quotes.map { DailyLedgerQuote(text: $0, sourceIDs: item.evidenceIDs, speaker: knowledge.ownedByUser ? "user" : "unknown") }
                return makeEntry(summary: summary, id: item.id, section: item.section.rawValue, title: item.title, detail: item.detail,
                    topic: knowledge.topic, kind: knowledge.kind, status: knowledge.status, owned: knowledge.ownedByUser, category: knowledge.category,
                    quotes: quotes, evidenceIDs: item.evidenceIDs, live: live, invalid: invalid, recordedAt: recordedAt,
                    reminderID: knowledge.reminderID, explicitCommitment: knowledge.explicitCommitment, condition: knowledge.condition, sourceVersions: knowledge.sourceVersions)
            }
        }
    }

    private func makeEntry(summary: DailySummary, id: UUID, section: String, title: String, detail: String,
                           topic: String?, kind: DailyItemKind, status: String, owned: Bool, category: String?,
                           quotes: [DailyLedgerQuote], evidenceIDs: [UUID], live: Set<UUID>, invalid: Set<UUID>,
                           recordedAt: [UUID: Date], reminderID: UUID? = nil, explicitCommitment: Bool? = nil,
                           condition: String? = nil, sourceVersions: [String: String]? = nil) -> Entry? {
        let sources = evidenceIDs.filter { live.contains($0) && !invalid.contains($0) }
        guard !sources.isEmpty else { return nil }
        let sourceSet = Set(sources)
        let userQuotes = quotes.filter { $0.speaker == "user" && !$0.sourceIDs.isEmpty }
        var keptKind = kind
        var keptOwned = owned
        if keptOwned && !userQuotes.isEmpty && !userQuotes.contains(where: { !$0.sourceIDs.filter(sourceSet.contains).isEmpty }) {
            keptOwned = false
            if keptKind != .reference { keptKind = .reference }
        }
        let keptQuotes = quotes.filter { $0.sourceIDs.isEmpty || !$0.sourceIDs.filter(sourceSet.contains).isEmpty }.map(\.text)
        var knowledge = DailyItemKnowledge(topic: topic, kind: keptKind, status: status, ownedByUser: keptOwned,
            quotes: keptQuotes.isEmpty ? quotes.map(\.text) : keptQuotes, category: category)
        knowledge.reminderID = reminderID
        knowledge.explicitCommitment = explicitCommitment
        knowledge.condition = condition
        knowledge.sourceVersions = sourceVersions
        let sectionValue = DailySummarySection(rawValue: section) ?? .progress
        let item = DailySummaryItem(id: id, section: sectionValue, title: title, detail: detail, evidenceIDs: sources, knowledge: knowledge)
        return Entry(summary: summary, item: item, knowledge: knowledge, sources: sources)
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
            let captures = Dictionary(uniqueKeysWithValues: state.captures.map { ($0.id, $0.createdAt) })
            let earliest = entry.sources.compactMap { captures[$0] }.min()
            var event = MatterEvent(id: Self.eventID(entry, key: key), title: topic,
                detail: entry.item.detail.isEmpty ? entry.item.title : entry.item.title + "：" + entry.item.detail,
                recordedAt: earliest ?? entry.summary.day, eventAt: earliest, status: Self.status(entry.knowledge.status),
                evidenceIDs: entry.sources.sorted { $0.uuidString < $1.uuidString },
                nextAction: entry.item.section.canonical == .actions ? entry.item.title : nil)
            event.quotes = entry.knowledge.quotes
            event.sequence = 0
            var current = groups[key] ?? (topic, [])
            // The latest name wins as the display title.
            current.name = topic
            current.events.append(event)
            groups[key] = current
        }
        return groups.map { key, value in
            let ordered = value.events.sorted { $0.date == $1.date ? $0.recordedAt == $1.recordedAt ? $0.id.uuidString < $1.id.uuidString : $0.recordedAt < $1.recordedAt : $0.date < $1.date }
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
            let captures = Dictionary(uniqueKeysWithValues: state.captures.map { ($0.id, $0.createdAt) })
            let earliest = entry.sources.compactMap { captures[$0] }.min()
            var event = MatterEvent(id: Self.eventID(entry, key: key), title: name,
                detail: entry.item.detail.isEmpty ? entry.item.title : entry.item.title + "：" + entry.item.detail,
                recordedAt: earliest ?? entry.summary.day, eventAt: earliest, status: .explored, evidenceIDs: entry.sources)
            event.quotes = entry.knowledge.quotes
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
            let quote = last.knowledge.quotes.first ?? (last.item.detail.isEmpty ? last.item.title : last.item.detail)
            var claim = MemoryClaim(id: identifier, key: identifier.uuidString, subjectID: "user",
                title: first.item.title, content: quote, kind: kind,
                state: .tentative, scope: .global, scopeID: nil, evidence: evidence,
                dependencies: [], supersedes: [], status: nil, resultStatus: nil, nextAction: nil,
                validFrom: first.summary.day, validUntil: Calendar.current.date(byAdding: .day, value: kind == .goal ? 30 : 180, to: last.summary.day),
                updatedAt: last.summary.day, explicit: false)
            if let until = claim.validUntil, until <= now { claim.state = .expired }
            return claim
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Topics whose name the question mentions. Matching uses the topic's identifying words, not the whole question,
    /// so "后台理解流程" reaches the topic "Recall 后台理解流程" and a bare word like "进展" reaches nothing.
    public func topics(matching question: String, in state: RecallState, limit: Int = 3) -> [MatterFile] {
        let wanted = Set(QuestionTerms.topicTerms(question).filter { $0.count >= 2 })
        guard !wanted.isEmpty else { return [] }
        let asked = question.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let scored = matterFiles(in: state).compactMap { file -> (MatterFile, Int)? in
            let name = file.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            var score = 0
            if asked.contains(name) { score += 100 }
            // Longer shared pieces say more than short ones; one short piece alone is too weak to select a topic.
            let own = Set(QuestionTerms.topicTerms(file.title).filter { $0.count >= 2 })
            let shared = wanted.intersection(own)
            score += shared.reduce(0) { $0 + $1.count * 3 }
            let long = shared.filter { $0.count >= 3 }.count
            guard score >= 100 || (long >= 1 && shared.count >= 2) || shared.count >= 3 else { return nil }
            return (file, score)
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0.latest.date > $1.0.latest.date : $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private static func eventID(_ entry: Entry, key: String) -> UUID {
        MatterEvidence.eventID(source: entry.summary.id, topic: key + "|" + entry.item.id.uuidString, ordinal: 0)
    }
}
