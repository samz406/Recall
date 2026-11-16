import Foundation

/// Recomputed from dated, current evidence; model confidence is a signal, not a personality score.
public enum PersonaProfileEngine {
    public static let horizonDays = 30
    public static func evidenceKey(_ observation: PersonaTraitObservation) -> String {
        CaptureUnderstandingEngine.digest("\(observation.day.timeIntervalSince1970)|\(observation.dimension.rawValue)|\(observation.value)|\(observation.evidenceQuote)")
    }
    public static func rebuild(from observations: [PersonaTraitObservation], now: Date = .now) -> [PersonaTraitState] {
        let calendar = Calendar.current, today = calendar.startOfDay(for: now)
        // A regenerated day replaces its earlier contribution, regardless of summary ID.
        var unique: [String: PersonaTraitObservation] = [:]
        for observation in observations.sorted(by: { $0.createdAt < $1.createdAt }) {
            let age = calendar.dateComponents([.day], from: observation.day, to: today).day ?? 0
            guard (0..<horizonDays).contains(age), observation.confidence >= 0.6,
                  observation.dimension.allowedValues.contains(observation.value) else { continue }
            unique["\(observation.day.timeIntervalSince1970)|\(observation.dimension.rawValue)"] = observation
        }
        return Dictionary(grouping: Array(unique.values), by: \.dimension).compactMap { dimension, values in
            let candidates = Dictionary(grouping: values, by: \.value).map { value, proofs -> PersonaTraitState in
                let weighted = proofs.map { proof in
                    let age = max(0, calendar.dateComponents([.day], from: proof.day, to: today).day ?? 0)
                    return proof.confidence * pow(0.9, Double(age))
                }
                let last = proofs.map(\.day).max() ?? today
                let age = calendar.dateComponents([.day], from: last, to: today).day ?? 0
                let strength = age > 14 ? 0 : 1 - weighted.reduce(1) { $0 * (1 - $1) }
                return PersonaTraitState(dimension: dimension, value: value, strength: strength,
                    observationDays: proofs.count, evidenceIDs: proofs.sorted { $0.day > $1.day }.map(\.id), updatedAt: last)
            }
            return candidates.sorted {
                if $0.strength != $1.strength { return $0.strength > $1.strength }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.value < $1.value
            }.first
        }.sorted { $0.dimension.rawValue < $1.dimension.rawValue }
    }
    public static func match(_ traits: [PersonaTraitState], excludingArchetypeIDs: Set<String> = [], now: Date = .now) -> PersonaMatch? {
        let current = traits.filter { $0.isConfirmed && now.timeIntervalSince($0.updatedAt) < 15 * 86_400 }
        let confirmed = Dictionary(uniqueKeysWithValues: current.map { ($0.dimension, $0) })
        guard confirmed.count >= 3 else { return nil }
        let candidates = PersonaArchetype.catalog.filter { !excludingArchetypeIDs.contains($0.id) }.compactMap { archetype -> PersonaMatch? in
            let signature = archetype.signatureDimensions
            // A known opposing observation must not be hidden by a few matching dimensions.
            for (dimension, value) in signature {
                if let trait = confirmed[dimension], trait.value != value { return nil }
            }
            let support = signature.filter { confirmed[$0.key]?.value == $0.value }.map(\.key).sorted { $0.rawValue < $1.rawValue }
            let coverage = Double(support.count) / Double(signature.count)
            guard support.count >= 3, coverage >= 0.75 else { return nil }
            let strength = support.reduce(0.0) { $0 + (confirmed[$1]?.strength ?? 0) } / Double(support.count)
            return PersonaMatch(archetypeID: archetype.id, name: archetype.name, tagline: archetype.tagline,
                score: coverage * strength, supportingDimensions: support, matchedAt: now)
        }.sorted { $0.score == $1.score ? $0.archetypeID < $1.archetypeID : $0.score > $1.score }
        guard let top = candidates.first else { return nil }
        // Keep concrete observations when the overall label remains ambiguous.
        if candidates.count > 1 && top.score - candidates[1].score < 0.12 { return nil }
        return top
    }
}
