import Foundation

public extension RecallState {
    private static var migratedPersonaVersion: String { "persona-v1-migrated" }
    /// Covers only what the analysis can read: the day's own reviewed items and the records they cite.
    /// Completing a todo or regenerating an unchanged review keeps the day's observations; editing,
    /// deleting or correcting a cited record still invalidates a late response.
    func personaSourceVersion(_ summary: DailySummary) -> String {
        let fingerprint = PersonaInsightEngine().fingerprint(for: summary)
        let versions = Dictionary(uniqueKeysWithValues: captures.filter { fingerprint.sourceIDs.contains($0.id) }.map {
            ($0.id, MemoryKnowledgeEngine.version(of: $0, corrections: matterCorrections))
        })
        return personaSourceVersion(fingerprint, versions: versions)
    }
    private func personaSourceVersion(_ fingerprint: (text: String, sourceIDs: Set<UUID>), versions: [UUID: String]) -> String {
        let sources = fingerprint.sourceIDs.sorted { $0.uuidString < $1.uuidString }.map { $0.uuidString + (versions[$0] ?? "missing") }.joined(separator: "|")
        return CaptureUnderstandingEngine.digest(fingerprint.text + "#" + sources)
    }

    /// Shared by every save/read path, including source deletion, feedback, retention and privacy exclusion.
    /// Never invokes a model. Only valid reviews in the recent 30 calendar days are queued, newest first.
    mutating func reconcilePersonaProfile(now: Date = .now, recoveringInterrupted: Bool = false) {
        if personaProfileVersion < 2 {
            // v1 versions hashed the whole review; v2 hashes only the analyzed evidence. Recheck once.
            if personaProfileVersion < 1 { personaTraitObservations = [] }
            personaTraits = []; personaRefreshJobs = []; pendingPersonaRefresh = []
            personaTraitObservations.removeAll { $0.dimension.isRetired }
            // Already validated against the review saved with them; rebound to the narrower version below.
            for i in personaTraitObservations.indices where personaTraitObservations[i].sourceVersion != nil {
                personaTraitObservations[i].sourceVersion = Self.migratedPersonaVersion
            }
            personaProfileVersion = 2
        }
        let calendar = Calendar.current
        let invalid = Set(matterCorrections.filter { $0.kind == .notMine || $0.kind == .inaccurate }.flatMap(\.evidenceIDs))
        let allowed = Set(captures.filter { !invalid.contains($0.id) && !privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") }.map(\.id))
        let today = calendar.startOfDay(for: now)
        let earliest = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        var dates: Set<Date> = []
        let summaries = dailySummaries.sorted { $0.createdAt > $1.createdAt }.filter {
            (earliest...today).contains($0.day) && !$0.sourceCaptureIDs.isEmpty && Set($0.sourceCaptureIDs).isSubset(of: allowed)
                && dates.insert(calendar.startOfDay(for: $0.day)).inserted
        }.sorted { $0.day > $1.day }.prefix(30)
        let engine = PersonaInsightEngine()
        let fingerprints = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, engine.fingerprint(for: $0)) })
        let relevant = Set(fingerprints.values.flatMap(\.sourceIDs))
        let sourceVersions = Dictionary(uniqueKeysWithValues: captures.filter { relevant.contains($0.id) }.map {
            ($0.id, MemoryKnowledgeEngine.version(of: $0, corrections: matterCorrections))
        })
        let versions = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, personaSourceVersion(fingerprints[$0.id]!, versions: sourceVersions)) })
        // One current review per day. Observations follow the day, so an unchanged regeneration keeps them.
        let current = Dictionary(uniqueKeysWithValues: summaries.map { (calendar.startOfDay(for: $0.day), $0) })
        let rejected = Set(rejectedPersonaEvidence)
        personaTraitObservations.removeAll { observation in
            guard let summary = current[observation.day], let version = observation.sourceVersion,
                  versions[summary.id] == version || version == Self.migratedPersonaVersion else { return true }
            return observation.dimension.isRetired || rejected.contains(PersonaProfileEngine.evidenceKey(observation))
        }
        for i in personaTraitObservations.indices {
            guard let summary = current[personaTraitObservations[i].day] else { continue }
            personaTraitObservations[i].sourceDailySummaryID = summary.id
            personaTraitObservations[i].sourceVersion = versions[summary.id]
        }
        let byVersion = Dictionary(summaries.map { (versions[$0.id]!, $0.id) }, uniquingKeysWith: { first, _ in first })
        personaRefreshJobs = personaRefreshJobs.compactMap { job in
            guard let summaryID = byVersion[job.sourceVersion] else { return nil }
            var job = job; job.summaryID = summaryID; return job
        }
        var seenJobs: Set<UUID> = []
        personaRefreshJobs.removeAll { !seenJobs.insert($0.summaryID).inserted }
        if recoveringInterrupted {
            for i in personaRefreshJobs.indices where personaRefreshJobs[i].status == .running {
                personaRefreshJobs[i].status = .queued
            }
        }
        if personaProfileSettings.enabled {
            let analyzed = Set(personaTraitObservations.map(\.day))
            for summary in summaries where !seenJobs.contains(summary.id) {
                var job = PersonaRefreshJob(summaryID: summary.id, sourceVersion: versions[summary.id]!)
                // Observations migrated from v1 already passed validation; only their version was too broad.
                if analyzed.contains(calendar.startOfDay(for: summary.day)) { job.status = .completed }
                personaRefreshJobs.append(job)
            }
        }
        let positions = Dictionary(uniqueKeysWithValues: summaries.enumerated().map { ($0.element.id, $0.offset) })
        personaRefreshJobs.sort { (positions[$0.summaryID] ?? 0) < (positions[$1.summaryID] ?? 0) }
        pendingPersonaRefresh = personaRefreshJobs.filter { $0.status == .queued || $0.status == .running }.map(\.summaryID)
        personaTraits = PersonaProfileEngine.rebuild(from: personaTraitObservations.filter { !dismissedPersonaDimensions.contains($0.dimension) }, now: now)
    }
    var confirmedPersonaTraits: [PersonaTraitState] { confirmedPersonaTraits() }
    /// Read-only and model-free. The archive is reconciled on every write, so this only applies time decay.
    func confirmedPersonaTraits(now: Date = .now) -> [PersonaTraitState] {
        PersonaProfileEngine.rebuild(from: personaTraitObservations.filter { !dismissedPersonaDimensions.contains($0.dimension) }, now: now)
            .filter(\.isConfirmed)
    }
    var mixedPersonaTraits: [PersonaTraitState] {
        PersonaProfileEngine.rebuild(from: personaTraitObservations.filter { !dismissedPersonaDimensions.contains($0.dimension) })
            .filter(\.isMixed)
    }
}
