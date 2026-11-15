import Foundation

/// Merges daily trait observations into a decayed rolling profile, and matches that profile against
/// the local persona catalog. Both operations are pure and local; neither calls a model.
public enum PersonaProfileEngine {
    /// Roughly a week's worth of inactivity nearly halves an unconfirmed signal's weight.
    static let decayPerDay = 0.9

    /// Folds new, already-validated observations into the existing trait states.
    /// A dimension only switches value when the new signal outweighs the decayed old one, and the
    /// day count restarts on a switch so a single day cannot present as a confirmed trait.
    public static func merge(existing: [PersonaTraitState], with observations: [PersonaTraitObservation], now: Date = .now) -> [PersonaTraitState] {
        guard !observations.isEmpty else { return existing }
        var byDimension = Dictionary(uniqueKeysWithValues: existing.map { ($0.dimension, $0) })
        let calendar = Calendar.current
        for observation in observations.sorted(by: { $0.day < $1.day }) {
            guard var current = byDimension[observation.dimension] else {
                byDimension[observation.dimension] = PersonaTraitState(
                    dimension: observation.dimension, value: observation.value, strength: observation.confidence,
                    observationDays: 1, evidenceIDs: [observation.id], updatedAt: now
                )
                continue
            }
            let elapsedDays = max(0, calendar.dateComponents([.day], from: current.updatedAt, to: now).day ?? 0)
            let decayed = current.strength * pow(decayPerDay, Double(elapsedDays))
            if current.value == observation.value {
                current.strength = min(1, decayed + observation.confidence * (1 - decayed))
                current.observationDays += 1
                current.evidenceIDs = Array((current.evidenceIDs + [observation.id]).suffix(14))
            } else if observation.confidence > decayed {
                current.value = observation.value
                current.strength = observation.confidence
                current.observationDays = 1
                current.evidenceIDs = [observation.id]
            } else {
                current.strength = decayed
            }
            current.updatedAt = now
            byDimension[observation.dimension] = current
        }
        return Array(byDimension.values).sorted { $0.dimension.rawValue < $1.dimension.rawValue }
    }

    /// Replays the remaining observations day by day (used after a source daily review is deleted,
    /// so the profile reflects only evidence that is still around) instead of trying to subtract
    /// one day's contribution from an already-decayed running state.
    public static func rebuild(from observations: [PersonaTraitObservation]) -> [PersonaTraitState] {
        let byDay = Dictionary(grouping: observations, by: \.day)
        var traits: [PersonaTraitState] = []
        for day in byDay.keys.sorted() { traits = merge(existing: traits, with: byDay[day] ?? [], now: day) }
        return traits
    }

    /// Best local match against the archetype catalog. Returns nil when there isn't yet enough
    /// confirmed, independent evidence to responsibly show a persona — "认识还不够" beats a wrong label.
    public static func match(_ traits: [PersonaTraitState], excludingArchetypeIDs: Set<String> = [], now: Date = .now) -> PersonaMatch? {
        let confirmed = Dictionary(uniqueKeysWithValues: traits.filter(\.isConfirmed).map { ($0.dimension, $0.value) })
        guard confirmed.count >= 3 else { return nil }
        let strengthByDimension = Dictionary(uniqueKeysWithValues: traits.map { ($0.dimension, $0.strength) })
        let scored: [(archetype: PersonaArchetype, score: Double, supporting: [PersonaDimension])] = PersonaArchetype.catalog
            .filter { !excludingArchetypeIDs.contains($0.id) }
            .map { archetype in
                let supporting = archetype.signatureDimensions.filter { confirmed[$0.key] == $0.value }.map(\.key)
                guard !supporting.isEmpty else { return (archetype, 0, []) }
                let averageStrength = supporting.reduce(0.0) { $0 + (strengthByDimension[$1] ?? 0) } / Double(supporting.count)
                let coverage = Double(supporting.count) / Double(archetype.signatureDimensions.count)
                return (archetype, coverage * (0.5 + 0.5 * averageStrength), supporting)
            }
            .sorted { $0.score > $1.score }
        guard let top = scored.first, top.supporting.count >= 2, top.score > 0 else { return nil }
        let runnerUp = scored.dropFirst().first
        let isClose = runnerUp.map { top.score - $0.score < 0.15 && $0.score > 0 } ?? false
        return PersonaMatch(
            archetypeID: top.archetype.id, name: top.archetype.name, tagline: top.archetype.tagline,
            score: top.score, supportingDimensions: top.supporting,
            alternateArchetypeID: isClose ? runnerUp?.archetype.id : nil, matchedAt: now
        )
    }
}
