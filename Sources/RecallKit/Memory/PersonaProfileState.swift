import Foundation

public extension RecallState {
    /// Includes source revisions, so a late response cannot survive editing, deletion or regeneration.
    func personaSourceVersion(_ summary: DailySummary) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        var current = summary; current.versions = nil
        let ids = Set(summary.sourceCaptureIDs)
        let versions = captures.filter { ids.contains($0.id) }.map {
            $0.id.uuidString + MemoryKnowledgeEngine.version(of: $0, corrections: matterCorrections)
        }.sorted().joined(separator: "|")
        return CaptureUnderstandingEngine.digest(String(decoding: (try? encoder.encode(current)) ?? Data(), as: UTF8.self) + versions)
    }

    /// Shared by every save/read path, including source deletion, feedback, retention and privacy exclusion.
    /// Never invokes a model. Only the latest 30 saved days are queued, newest first.
    mutating func reconcilePersonaProfile(now: Date = .now, recoveringInterrupted: Bool = false) {
        if personaProfileVersion < 1 {
            // Legacy observations did not establish ownership or independent dates. Recheck the reviews.
            personaTraitObservations = []; personaTraits = []; personaMatch = nil; personaMatchHistory = []
            personaRefreshJobs = []; pendingPersonaRefresh = []; personaProfileVersion = 1
        }
        let invalid = Set(matterCorrections.filter { $0.kind == .notMine || $0.kind == .inaccurate }.flatMap(\.evidenceIDs))
        let allowed = Set(captures.filter { !invalid.contains($0.id) && !privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") }.map(\.id))
        let today = Calendar.current.startOfDay(for: now)
        var dates: Set<Date> = []
        let summaries = dailySummaries.sorted { $0.createdAt > $1.createdAt }.filter {
            $0.day <= today && !$0.sourceCaptureIDs.isEmpty && Set($0.sourceCaptureIDs).isSubset(of: allowed)
                && dates.insert(Calendar.current.startOfDay(for: $0.day)).inserted
        }.sorted { $0.day > $1.day }
        let versions = Dictionary(uniqueKeysWithValues: summaries.prefix(30).map { ($0.id, personaSourceVersion($0)) })
        let previousCount = personaTraitObservations.count
        let rejected = Set(rejectedPersonaEvidence)
        personaTraitObservations.removeAll { observation in
            observation.sourceVersion == nil || versions[observation.sourceDailySummaryID] != observation.sourceVersion
                || rejected.contains(PersonaProfileEngine.evidenceKey(observation))
        }
        if personaTraitObservations.count != previousCount { personaMatchHistory = [] }
        personaRefreshJobs.removeAll { versions[$0.summaryID] != $0.sourceVersion }
        if recoveringInterrupted {
            for i in personaRefreshJobs.indices where personaRefreshJobs[i].status == .running {
                personaRefreshJobs[i].status = .queued
            }
        }
        if personaProfileSettings.enabled {
            for summary in summaries.prefix(30) where !personaRefreshJobs.contains(where: { $0.summaryID == summary.id }) {
                personaRefreshJobs.append(PersonaRefreshJob(summaryID: summary.id, sourceVersion: versions[summary.id]!))
            }
        }
        let positions = Dictionary(uniqueKeysWithValues: summaries.enumerated().map { ($0.element.id, $0.offset) })
        personaRefreshJobs.sort { (positions[$0.summaryID] ?? 0) < (positions[$1.summaryID] ?? 0) }
        pendingPersonaRefresh = personaRefreshJobs.filter { $0.status == .queued || $0.status == .running }.map(\.summaryID)
        personaTraits = PersonaProfileEngine.rebuild(from: personaTraitObservations.filter { !dismissedPersonaDimensions.contains($0.dimension) }, now: now)
        let stamp = personaEvidenceStamp
        if personaProfileSettings.showsArchetype && stamp != rejectedPersonaMatchStamp {
            personaMatch = PersonaProfileEngine.match(personaTraits, excludingArchetypeIDs: Set(dismissedPersonaArchetypeIDs), now: now)
        } else { personaMatch = nil }
    }
    var personaEvidenceStamp: String {
        CaptureUnderstandingEngine.digest(personaTraitObservations.map(PersonaProfileEngine.evidenceKey).sorted().joined(separator: "|"))
    }
    var confirmedPersonaTraits: [PersonaTraitState] {
        PersonaProfileEngine.rebuild(from: personaTraitObservations.filter { !dismissedPersonaDimensions.contains($0.dimension) })
            .filter(\.isConfirmed).sorted { $0.strength == $1.strength ? $0.dimension.rawValue < $1.dimension.rawValue : $0.strength > $1.strength }
    }
}
