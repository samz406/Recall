import Foundation

public struct DailyReminderCompletion: Codable, Hashable, Sendable {
    public var summaryID: UUID
    public var itemID: UUID
    public var itemVersion: String
    public var appliedAt: Date
    public var sourceVersions: [String: String]
}

public struct DailyReminderProvenance: Codable, Hashable, Sendable {
    public var summaryID: UUID
    public var itemID: UUID
    public var actionID: UUID
    public var identity: String
    public var topic: String?
    public var sourceVersions: [String: String]
    public var completion: DailyReminderCompletion? = nil
}

public struct DailyReminderSync: Sendable {
    public var added = 0, completed = 0, withdrawn = 0
    public var changed: Bool { added + completed + withdrawn > 0 }
}

/// The model already decided meaning in the day-wide review. This projector only
/// checks provenance/state, performs exact deduplication and never calls a model.
public enum DailyReviewReminderEngine {
    private struct Context: Codable {
        var id: UUID; var revision: String; var title: String; var topic: String?; var commitment: [String]
    }
    public static func context(in state: RecallState, before end: Date) -> String {
        guard state.reminderLearningProfile.reviewDiscoveryEnabled != false else { return "[]" }
        let safe = state.correctedForAnalysis()
        let sources = Dictionary(uniqueKeysWithValues: safe.captures.map { ($0.id, $0) })
        var values: [Context] = [], bytes = 0
        for reminder in state.reminders.sorted(by: { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }) {
            guard reminder.origin == .discovered, !reminder.status.isHistory, reminder.recurrence == .none,
                  reminder.createdAt < end, let provenance = reminder.analysis?.dailyReview,
                  provenance.sourceVersions.allSatisfy({ key, version in
                      UUID(uuidString: key).flatMap { sources[$0] }.map { CaptureUnderstandingEngine.sourceVersion($0, in: safe) == version } == true
                  }),
                  !reminder.sourceCaptureIDs.isEmpty, reminder.sourceCaptureIDs.allSatisfy({ id in
                      sources[id].map { permitted($0, state: state) } == true
                  }) else { continue }
            let value = Context(id: reminder.id, revision: SummaryFeedbackLearning.hash(reminder), title: PrivacyEngine().redact(String(reminder.title.prefix(90))),
                topic: reminder.analysis?.dailyReview?.topic.map { PrivacyEngine().redact(String($0.prefix(30))) },
                commitment: Array(Set(reminder.analysis?.evidence.map(\.quote) ?? [])).sorted().prefix(2).map { PrivacyEngine().redact(String($0.prefix(120))) })
            let size = ((try? directReviewJSON(value)) ?? "").utf8.count
            guard bytes + size < 6_000, values.count < 24 else { break }
            bytes += size; values.append(value)
        }
        return (try? directReviewJSON(values)) ?? "[]"
    }
    static func contextIDs(_ text: String) -> Set<UUID> {
        Set(((try? JSONDecoder().decode([Context].self, from: Data(text.utf8))) ?? []).map(\.id))
    }

    static func permitted(_ record: CaptureRecord, state: RecallState) -> Bool {
        !record.ocrText.isEmpty && record.memoryDirective == nil && record.eventTemplate != .dailyReview
            && record.isMemoryEvidenceArchive != true
            && !state.privacy.excludedBundleIdentifiers.contains(record.sourceBundleIdentifier ?? "")
            && state.reminderLearningProfile.permitsReminderDiscovery(from: record)
            && !state.matterCorrections.contains { $0.evidenceIDs.contains(record.id) && ($0.kind == .notMine || $0.kind == .inaccurate) }
    }

    static func itemVersion(_ item: DailySummaryItem) -> String {
        var copy = item
        copy.knowledge?.sourceVersions = nil
        return SummaryFeedbackLearning.hash(copy)
    }
    private static func fingerprint(_ summary: DailySummary, sources: [UUID: CaptureRecord], state: RecallState) -> String {
        let ids = Set(summary.items.flatMap(\.evidenceIDs)).sorted { $0.uuidString < $1.uuidString }
        let versions = ids.map { id -> String in
            guard let source = sources[id], permitted(source, state: state) else { return id.uuidString + ":excluded" }
            return id.uuidString + ":" + CaptureUnderstandingEngine.sourceVersion(source, in: state)
        }
        return SummaryFeedbackLearning.hash([summary.id.uuidString, SummaryFeedbackLearning.revision(in: state)] + summary.items.map(itemVersion) + versions)
    }

    /// Every cited quote must still occur in its source. At least one is explicitly
    /// the user's own speech, not reference material, another party or an assistant.
    private static func evidence(_ item: DailySummaryItem, sources: [UUID: CaptureRecord], state: RecallState, strictOwn: Bool = false) -> [UnderstandingEvidence]? {
        guard let knowledge = item.knowledge, knowledge.ownedByUser, knowledge.kind == .matter,
              knowledge.condition?.isEmpty ?? true, !knowledge.quotes.isEmpty, !item.evidenceIDs.isEmpty,
              item.evidenceIDs.allSatisfy({ sources[$0].map { permitted($0, state: state) } == true }) else { return nil }
        if let versions = knowledge.sourceVersions {
            guard Set(versions.keys) == Set(item.evidenceIDs), versions.allSatisfy({ id, version in
                sources[id].map { CaptureUnderstandingEngine.sourceVersion($0, in: state) == version } == true
            }) else { return nil }
        } else if item.evidenceIDs.contains(where: { sources[$0]?.correctedText != nil }) { return nil }
        let blocks = item.evidenceIDs.flatMap { sources[$0].map { CaptureUnderstandingEngine.blocks(for: $0) } ?? [] }
        var result: [UnderstandingEvidence] = [], own = false
        for quote in knowledge.quotes {
            let matches = blocks.filter { $0.text.contains(quote) }
            guard quote.count >= 4, let block = matches.first(where: { !$0.isReference && $0.speaker == .user }) ?? matches.first else { return nil }
            if strictOwn && (block.isReference || block.speaker != .user || (block.confidence ?? 1) < 0.5) { return nil }
            if !block.isReference && block.speaker == .user && (block.confidence ?? 1) >= 0.5 { own = true }
            result.append(UnderstandingEvidence(blockID: block.id, quote: quote))
        }
        return own ? result : nil
    }

    @discardableResult
    public static func reconcile(_ state: inout RecallState, now: Date = .now) -> DailyReminderSync {
        var outcome = DailyReminderSync()
        guard state.reminderLearningProfile.reviewDiscoveryEnabled != false else { return outcome }
        let safe = state.correctedForAnalysis()
        let sources = Dictionary(uniqueKeysWithValues: safe.captures.map { ($0.id, $0) })
        let summaries = state.dailySummaries.filter { $0.generationKind == .cloud && $0.modelCoverage != nil }
            .sorted { $0.day == $1.day ? $0.createdAt < $1.createdAt : $0.day < $1.day }
        var marks = state.reminderLearningProfile.reviewedDailyFingerprints ?? [:]
        // A correction or deletion must not leave an untouched automatic completion in force.
        for i in state.reminders.indices {
            guard let done = state.reminders[i].analysis?.dailyReview?.completion,
                  state.reminders[i].status == .completed, state.reminders[i].updatedAt == done.appliedAt else { continue }
            let permittedSources = state.reminders[i].sourceCaptureIDs.allSatisfy { sources[$0].map { permitted($0, state: safe) } == true }
            let validItem = summaries.first(where: { $0.id == done.summaryID })?.items.contains {
                $0.id == done.itemID && $0.section == .progress && $0.knowledge?.status == "completed"
                    && itemVersion($0) == done.itemVersion && evidence($0, sources: sources, state: safe, strictOwn: true) != nil
            } == true
            let validSources = done.sourceVersions.allSatisfy { key, version in
                UUID(uuidString: key).flatMap { sources[$0] }.map { CaptureUnderstandingEngine.sourceVersion($0, in: safe) == version } == true
            }
            let validOrigin = state.reminders[i].analysis?.dailyReview?.sourceVersions.allSatisfy { key, version in
                UUID(uuidString: key).flatMap { sources[$0] }.map { CaptureUnderstandingEngine.sourceVersion($0, in: safe) == version } == true
            } == true
            let valid = permittedSources && validItem && validSources && validOrigin
            if !valid {
                state.reminders[i].status = .proposed; state.reminders[i].closedAt = nil; state.reminders[i].completedAt = nil
                state.reminders[i].scheduledAt = nil; state.reminders[i].updatedAt = now
                state.reminders[i].analysis?.dailyReview?.completion = nil
                state.reminders[i].analysis?.basis = "完成依据已变化，请重新确认"
                outcome.withdrawn += 1
            }
        }
        for summary in summaries {
            let version = fingerprint(summary, sources: sources, state: safe)
            guard marks[summary.id.uuidString] != version else { continue }
            for item in summary.items {
                guard let knowledge = item.knowledge, let proofs = evidence(item, sources: sources, state: safe) else { continue }
                let versions = Dictionary(item.evidenceIDs.compactMap { id in
                    sources[id].map { (id.uuidString, CaptureUnderstandingEngine.sourceVersion($0, in: safe)) }
                }, uniquingKeysWith: { first, _ in first })
                if item.section == .progress, knowledge.status == "completed", let id = knowledge.reminderID,
                   let i = state.reminders.firstIndex(where: { $0.id == id && $0.origin == .discovered && !$0.status.isHistory && $0.recurrence == .none && $0.analysis?.dailyReview != nil }),
                   knowledge.reminderRevision == SummaryFeedbackLearning.hash(state.reminders[i]),
                   evidence(item, sources: sources, state: safe, strictOwn: true) != nil,
                   state.reminders[i].sourceCaptureIDs.allSatisfy({ sources[$0].map { permitted($0, state: safe) } == true }),
                   state.reminders[i].analysis!.dailyReview!.sourceVersions.allSatisfy({ key, version in
                       UUID(uuidString: key).flatMap { sources[$0] }.map { CaptureUnderstandingEngine.sourceVersion($0, in: safe) == version } == true
                   }),
                   let latest = item.evidenceIDs.compactMap({ sources[$0]?.createdAt }).max(), latest > state.reminders[i].createdAt {
                    state.reminders[i].status = .completed; state.reminders[i].completedAt = latest
                    state.reminders[i].closedAt = latest; state.reminders[i].updatedAt = now
                    state.reminders[i].sourceCaptureIDs = Array(Set(state.reminders[i].sourceCaptureIDs + item.evidenceIDs)).sorted { $0.uuidString < $1.uuidString }
                    state.reminders[i].analysis?.basis = "后续每日回顾确认你已完成"
                    state.reminders[i].analysis?.evidence += proofs
                    state.reminders[i].analysis?.dailyReview?.completion = DailyReminderCompletion(summaryID: summary.id, itemID: item.id,
                        itemVersion: itemVersion(item), appliedAt: now, sourceVersions: versions)
                    outcome.completed += 1
                } else if item.section == .actions, knowledge.status == "pending", knowledge.explicitCommitment != false,
                          let actionID = item.actionCandidateID, summary.todos.contains(where: { $0.id == actionID && ($0.status == .pending || $0.status == .inProgress) }),
                          !SummaryFeedbackLearning.rejectsAction(title: item.title, sourceIDs: item.evidenceIDs, in: safe) {
                    let words = knowledge.quotes.sorted().joined(separator: "|")
                    let scopes = Set(item.evidenceIDs.compactMap { sources[$0] }.map { ($0.sourceBundleIdentifier ?? $0.sourceAppName ?? "") + "|" + ($0.windowTitle ?? "") }).sorted()
                    let identity = CaptureUnderstandingEngine.digest((knowledge.topic ?? "") + "|" + words + "|" + scopes.joined(separator: "|"))
                    let linked = knowledge.reminderID.flatMap { id in state.reminders.firstIndex { $0.id == id } }
                    let exact = state.reminders.firstIndex {
                        $0.id == actionID || $0.analysis?.dailyReview?.identity == identity
                            || ($0.origin == .discovered && $0.title == item.title && !Set($0.sourceCaptureIDs).isDisjoint(with: item.evidenceIDs))
                    }
                    if let i = linked ?? exact {
                        guard !state.reminders[i].status.isHistory else { continue }
                        guard state.reminders[i].status == .proposed, state.reminders[i].origin == .discovered,
                              linked == nil || knowledge.reminderRevision == SummaryFeedbackLearning.hash(state.reminders[i]) else { continue }
                        state.reminders[i].sourceCaptureIDs = Array(Set(state.reminders[i].sourceCaptureIDs + item.evidenceIDs)).sorted { $0.uuidString < $1.uuidString }
                        state.reminders[i].analysis = ReminderAnalysis(version: 1, basis: "每日回顾中的本人未完成承诺", evidence: proofs)
                        state.reminders[i].analysis?.dailyReview = DailyReminderProvenance(summaryID: summary.id, itemID: item.id,
                            actionID: actionID, identity: identity, topic: knowledge.topic, sourceVersions: versions)
                        // Preserve user-edited fields and times; no need to rewrite an existing candidate's text.
                    } else {
                        if knowledge.reminderID != nil { continue }
                        let date = item.evidenceIDs.compactMap { sources[$0]?.createdAt }.min() ?? summary.day
                        var candidate = ReminderCandidate(id: actionID, title: item.title, detail: item.detail, sourceCaptureIDs: item.evidenceIDs,
                            confidence: 1, createdAt: date, semanticKey: "daily:" + identity)
                        candidate.analysis = ReminderAnalysis(version: 1, basis: "每日回顾中的本人未完成承诺", evidence: proofs)
                        candidate.analysis?.dailyReview = DailyReminderProvenance(summaryID: summary.id, itemID: item.id,
                            actionID: actionID, identity: identity, topic: knowledge.topic, sourceVersions: versions)
                        guard !state.reminderLearningProfile.suppressesHistory(candidate, now: now),
                              !state.reminders.contains(where: { $0.status.isHistory && ReminderExtractor().blocks(candidate: candidate, existing: $0, now: now) }) else { continue }
                        state.reminders.append(candidate); outcome.added += 1
                    }
                }
            }
            marks[summary.id.uuidString] = version
        }
        // Only withdraw weak, unconfirmed proposals when their exact review row no longer exists.
        let before = state.reminders.count
        state.reminders.removeAll { reminder in
            guard reminder.origin == .discovered, reminder.status == .proposed, let provenance = reminder.analysis?.dailyReview,
                  provenance.completion == nil else { return false }
            guard reminder.sourceCaptureIDs.allSatisfy({ sources[$0].map { permitted($0, state: safe) } == true }) else { return true }
            if SummaryFeedbackLearning.rejectsAction(title: reminder.title, sourceIDs: reminder.sourceCaptureIDs, in: safe) { return true }
            guard let report = summaries.first(where: { $0.id == provenance.summaryID }),
                  let item = report.items.first(where: { $0.id == provenance.itemID && $0.section == .actions }) else { return true }
            return evidence(item, sources: sources, state: safe) == nil
        }
        outcome.withdrawn += before - state.reminders.count
        let live = Set(summaries.map { $0.id.uuidString })
        state.reminderLearningProfile.reviewedDailyFingerprints = marks.filter { live.contains($0.key) }
        return outcome
    }
}

public extension FileMemoryStore {
    @discardableResult
    func syncDailyReviewReminders(now: Date = .now) throws -> DailyReminderSync {
        let previous = state
        let outcome = DailyReviewReminderEngine.reconcile(&state, now: now)
        if previous.reminders != state.reminders || previous.reminderLearningProfile != state.reminderLearningProfile {
            do { try persistReviewState() } catch { state = previous; throw error }
        }
        return outcome
    }
    func setReviewReminderDiscovery(_ enabled: Bool) throws {
        let previous = state
        state.reminderLearningProfile.reviewDiscoveryEnabled = enabled
        DailyReviewReminderEngine.reconcile(&state)
        do { try persistReviewState() } catch { state = previous; throw error }
    }
}
