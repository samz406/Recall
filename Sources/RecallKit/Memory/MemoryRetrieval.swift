import Foundation

public struct MemoryRetrievalPlan: Sendable {
    public var evidence: [CaptureRecord]
    public var preferences: String?
    public var sourceIDs: [UUID: [UUID]]
    public var preferenceSourceIDs: [UUID]
    public var needsSemanticLookup: Bool
    public var passes: Int
}

/// Bounded two-pass retrieval: locate an entity/statement, then fetch its original evidence.
/// Rankings never make a statement true; only active statements and live sources may be used.
public struct MemoryRetrievalEngine: Sendable {
    public init() {}
    public func plan(question: String, state: RecallState, fallback: [CaptureRecord], conversationID: UUID? = nil,
                     limit: Int = 14, now: Date = .now, resolvedEntityIDs: Set<String> = []) -> MemoryRetrievalPlan {
        let safe = state.correctedForAnalysis()
        let participating = safe.captures.filter { record in
            let participates = state.rules.first(where: { $0.template == record.eventTemplate })?.participatesInChat ?? true
            return participates && !state.privacy.excludedBundleIdentifiers.contains(record.sourceBundleIdentifier ?? "")
        }
        let allowedIDs = Set(participating.map(\.id))
        let allowed = participating.map { $0.scopingUnderstanding(to: allowedIDs) }
        let restrictedUnderstandingIDs = Set(zip(participating, allowed).filter { $0.0.understanding != nil && $0.1.understanding == nil }.map { $0.0.id })
        let ledger = MemoryKnowledgeEngine().reconcile(state)
        let active = ledger.claims.filter { claim in
            ledger.organizationVersion == MemoryKnowledgeEngine.organizationVersion
                && (!MemoryLibraryCategory.all.includes(claim.kind) || state.memoryKnowledgeSettings.references(claim))
                && claim.usable(at: now) && !claim.sourceIDs.isEmpty && Set(claim.sourceIDs).isSubset(of: allowedIDs)
                && Set(claim.sourceIDs).isDisjoint(with: restrictedUnderstandingIDs)
        }
        let retiredSources = Set(ledger.claims.filter {
            ([.retracted, .superseded, .conflicted, .expired].contains($0.state) && ($0.kind.isPersonal || $0.kind == .reference))
                || (MemoryLibraryCategory.all.includes($0.kind) && !state.memoryKnowledgeSettings.references($0))
        }.flatMap(\.sourceIDs))
        let time = MemoryTimeRangeResolver().resolve(question, now: now)
        let intent = MemoryQuestionIntent(question: question)
        var terms = Set(QuestionTerms.topicTerms(question)).union(MatterMemoryEngine.subjectTerms(QuestionTerms.stripped(question)))
        let entities = ledger.entities.filter { entity in
            Set(entity.sourceIDs).isSubset(of: allowedIDs) && Set(entity.sourceIDs).isDisjoint(with: restrictedUnderstandingIDs)
                && (resolvedEntityIDs.contains(entity.id) || ([entity.name] + entity.aliases).contains { !$0.isEmpty && question.localizedCaseInsensitiveContains($0) })
        }
        for entity in entities { terms.formUnion(MatterMemoryEngine.subjectTerms(entity.name)) }
        let matchingGroups = state.topicGroups.filter { question.localizedCaseInsensitiveContains($0.title) || resolvedEntityIDs.contains($0.id) }
        let entityIDs = Set(entities.map(\.id) + matchingGroups.flatMap(\.memberIDs))
        func relevance(_ claim: MemoryClaim) -> Int {
            let text = claim.title + " " + claim.content
            let count = terms.filter { text.localizedCaseInsensitiveContains($0) }.count
            let entity = entityIDs.contains(claim.subjectID) ? 40 : 0
            let purpose = intent == .solution && claim.kind == .experience ? 12 : 0
            return count * 4 + entity + purpose
        }
        let candidates = active.filter { claim in
            if claim.kind.isPersonal && !MemoryPersonalization.applies(claim, question: question, entities: entityIDs, conversationID: conversationID) { return false }
            if let time {
                guard claim.date >= time.startDate && claim.date <= time.endDate else { return false }
                return intent == .overview ? [.event, .reference].contains(claim.kind) : relevance(claim) > 0
            }
            return relevance(claim) > 0
        }.sorted { a, b in
            let x = relevance(a), y = relevance(b)
            return x == y ? a.date > b.date : x > y
        }
        // Topics named in the question come first: their whole timeline (first and latest state included) is
        // the answer's backbone, ahead of anything a keyword happened to hit.
        let namedTopics = DailyKnowledgeEngine().topics(matching: question, in: state)
        var selected: [MemoryClaim] = []
        if let time, intent == .overview {
            let calendar = Calendar.current
            let days = Dictionary(grouping: candidates) { calendar.startOfDay(for: $0.date) }
            let ordered = days.keys.sorted()
            let dayLimit = min(limit, ordered.count)
            for index in 0..<dayLimit {
                let position = dayLimit <= 1 ? 0 : Int((Double(index) * Double(ordered.count - 1) / Double(dayLimit - 1)).rounded())
                if let item = days[ordered[position]]?.first { selected.append(item) }
            }
            _ = time
        } else if [.status, .change, .decision].contains(intent), let first = candidates.first {
            let related = candidates.filter { $0.subjectID == first.subjectID }.sorted { $0.date < $1.date }
            if let earliest = related.first { selected.append(earliest) }
            if let latest = related.last, latest.id != selected.first?.id { selected.append(latest) }
        }
        var topicClaims: [MemoryClaim] = []
        for topic in namedTopics {
            let events = active.filter { $0.kind == .event && $0.subjectID == topic.id }.sorted { $0.date < $1.date }
            // Up to the earliest, the latest, and the points where the status changed in between.
            var picked: [MemoryClaim] = []
            for (index, event) in events.enumerated() {
                let changed = index == 0 || index == events.count - 1 || event.status != events[index - 1].status
                if changed { picked.append(event) }
            }
            topicClaims += picked.suffix(6)
        }
        var chosen = Set(selected.map(\.id))
        for claim in topicClaims where chosen.insert(claim.id).inserted { selected.insert(claim, at: 0) }
        for item in candidates where selected.count < max(limit - 2, 2) {
            if chosen.insert(item.id).inserted { selected.append(item) }
        }
        var evidence: [CaptureRecord] = []
        var sources: [UUID: [UUID]] = [:]
        for claim in selected.prefix(limit) {
            let timeNote = claim.evidence.contains { $0.eventAt != nil } ? "用户提供了发生时间" : "仅知首次记录时间，不保证发生于当日"
            let history: String
            if claim.kind == .event, let latest = active.filter({ $0.kind == .event && $0.subjectID == claim.subjectID }).max(by: { $0.date < $1.date }), latest.id != claim.id {
                history = "历史记录，不能当作当前状态；需结合同主题的后续依据"
            } else { history = claim.kind == .reference ? "保存的内容线索；说话人与实际状态未确认，不能当作用户成果、承诺或偏好" : "有效记录" }
            let text = "主题：\(claim.title)\n\(history)；\(timeNote)\n原文：\(claim.content)" + (claim.nextAction.map { "\n明确后续行动：\($0)" } ?? "")
            let record = CaptureRecord(id: claim.id, eventTemplate: .manualMoment, createdAt: claim.date,
                sourceAppName: claim.kind.title, sourceBundleIdentifier: "im.recall.memory-claim", contentHash: claim.key,
                ocrText: text, tags: [claim.title])
            evidence.append(record); sources[record.id] = claim.sourceIDs
        }
        // Second pass expands the located topic and aliases to original records, not just the initial keyword hits.
        let sourceAnchorIDs = Set(selected.flatMap(\.sourceIDs))
        let aliasText = entities.map(\.name).joined(separator: " ")
        func mentionsEntity(_ record: CaptureRecord) -> Bool {
            entities.contains { entity in
                ([entity.name] + entity.aliases).contains { record.ocrText.localizedCaseInsensitiveContains($0) }
            }
        }
        let expanded = aliasText.isEmpty ? [] : MemorySearchEngine().search(MemorySearchQuery(text: aliasText,
            startDate: time?.startDate, endDate: time?.endDate), in: allowed, limit: 24).map(\.capture).filter(mentionsEntity)
        var raw = allowed.filter { sourceAnchorIDs.contains($0.id) } + expanded + fallback
        var seen = Set(evidence.map(\.id))
        raw = raw.filter { record in
            guard !retiredSources.contains(record.id), seen.insert(record.id).inserted else { return false }
            if record.memoryDirective != nil {
                guard active.contains(where: { $0.sourceIDs.contains(record.id) && MemoryPersonalization.applies($0, question: question, entities: entityIDs, conversationID: conversationID) }) else { return false }
            }
            if !entities.isEmpty, [.status, .change, .decision, .solution].contains(intent),
               !sourceAnchorIDs.contains(record.id), !mentionsEntity(record) { return false }
            if let time { return record.createdAt >= time.startDate && record.createdAt <= time.endDate }
            return true
        }
        let poolLimit = time != nil && intent == .overview ? limit * 4 : limit
        for record in raw where evidence.count < poolLimit {
            var selectedRecord = record
            let ids: [UUID]
            if allowedIDs.contains(record.id) {
                let dependencies = Set(record.understanding?.sourceVersions.keys.map { $0 } ?? [])
                if !dependencies.isEmpty && dependencies.isSubset(of: allowedIDs) && dependencies.isDisjoint(with: retiredSources) {
                    ids = dependencies.sorted { $0.uuidString < $1.uuidString }
                } else { selectedRecord.understanding = nil; ids = [record.id] }
            }
            else if let summary = safe.dailySummaries.first(where: { $0.id == record.id }) {
                // Legacy reports remain labelled as unverified, deletable historical sources.
                ids = summary.sourceCaptureIDs.isEmpty && state.matterCorrections.isEmpty
                    && !state.privacy.excludedBundleIdentifiers.contains("im.recall.daily-summary")
                    ? [summary.id] : summary.sourceCaptureIDs
            }
            else if let episode = safe.episodes.first(where: { $0.id == record.id }) { ids = episode.evidenceIDs }
            else if let memory = safe.userMemories.first(where: { $0.id == record.id }) { ids = memory.evidenceIDs }
            else { continue }
            let legacy = ids == [record.id] && safe.dailySummaries.contains { $0.id == record.id && $0.sourceCaptureIDs.isEmpty }
            guard !ids.isEmpty, legacy || Set(ids).isSubset(of: allowedIDs), Set(ids).isDisjoint(with: retiredSources) else { continue }
            evidence.append(selectedRecord); sources[record.id] = ids
        }
        if time != nil && intent == .overview { evidence = temporalCoverage(evidence, limit: limit) }
        let preferences = preferenceContext(question: question, claims: active, conversationID: conversationID, entities: entityIDs, now: now)
        let preferenceSources = active.filter { claim in preferences?.contains(claim.content) == true && claim.kind.isPersonal }.flatMap(\.sourceIDs).memoryUnique()
        return MemoryRetrievalPlan(evidence: evidence, preferences: preferences, sourceIDs: sources,
            preferenceSourceIDs: preferenceSources,
            needsSemanticLookup: selected.isEmpty && intent != .overview,
            passes: selected.isEmpty && expanded.isEmpty ? 1 : 2)
    }

    private func temporalCoverage(_ records: [CaptureRecord], limit: Int) -> [CaptureRecord] {
        guard limit > 0 else { return [] }
        let calendar = Calendar.current
        let groups = Dictionary(grouping: records) { calendar.startOfDay(for: $0.createdAt) }
        let days = groups.keys.sorted()
        let count = min(days.count, limit)
        var result: [CaptureRecord] = []
        var seen: Set<UUID> = []
        for index in 0..<count {
            let offset = count <= 1 ? 0 : Int((Double(index) * Double(days.count - 1) / Double(count - 1)).rounded())
            let dayRecords = groups[days[offset]] ?? []
            if let first = dayRecords.first(where: { $0.eventTemplate == .dailyReview }) ?? dayRecords.first {
                result.append(first); seen.insert(first.id)
            }
        }
        for record in records where result.count < limit {
            if seen.insert(record.id).inserted { result.append(record) }
        }
        return result
    }

    public func preferenceContext(question: String, claims: [MemoryClaim], conversationID: UUID?, entities: Set<String> = [], now: Date = .now) -> String? {
        let relevant = claims.filter { claim in
            [.preference, .constraint, .workflow].contains(claim.kind) && claim.usable(at: now)
                && MemoryPersonalization.applies(claim, question: question, entities: entities, conversationID: conversationID)
        }.sorted { a, b in
            func priority(_ item: MemoryClaim) -> Int {
                switch item.scope { case .conversation: 4; case .project: 3; case .global: 1; default: 2 }
            }
            let x = priority(a), y = priority(b)
            return x == y ? a.updatedAt > b.updatedAt : x > y
        }
        guard !relevant.isEmpty else { return nil }
        var budget = 0
        var lines: [String] = [], slots: Set<String> = []
        for item in relevant where lines.count < 8 && budget + item.content.count <= 2400 {
            if let slot = MemoryPersonalization.preferenceSlot(item.content), !slots.insert(slot).inserted { continue }
            lines.append("- \(item.scope.title) · \(item.explicit ? "本人明确约定" : "本人陈述")：\(item.content)")
            budget += item.content.count
        }
        guard !lines.isEmpty else { return nil }
        return "当前任务适用的用户约定（只调整表达和组织；本次会话约定优先。不扩大采集、联网、通知、发送或执行权限；不把偏好写成当天成果）：\n" + lines.joined(separator: "\n")
    }
}
