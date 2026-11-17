import Foundation

/// Recomputed from dated, current evidence; model confidence is a signal, not a personality score.
public enum PersonaProfileEngine {
    public static let horizonDays = 30
    public static func evidenceKey(_ observation: PersonaTraitObservation) -> String {
        CaptureUnderstandingEngine.digest("\(observation.day.timeIntervalSince1970)|\(observation.dimension.rawValue)|\(observation.value)|\(observation.evidenceQuote)")
    }
    /// Sorted by strength, so callers taking a prefix get the best-supported traits first.
    public static func rebuild(from observations: [PersonaTraitObservation], now: Date = .now) -> [PersonaTraitState] {
        let calendar = Calendar.current, today = calendar.startOfDay(for: now)
        func age(_ day: Date) -> Int { max(0, calendar.dateComponents([.day], from: day, to: today).day ?? 0) }
        // A regenerated day replaces its earlier contribution, regardless of summary ID.
        var unique: [String: PersonaTraitObservation] = [:]
        for observation in observations.sorted(by: { $0.createdAt < $1.createdAt }) {
            let days = calendar.dateComponents([.day], from: observation.day, to: today).day ?? 0
            guard (0..<horizonDays).contains(days), observation.confidence >= 0.6, !observation.dimension.isRetired,
                  observation.dimension.allowedValues.contains(observation.value) else { continue }
            unique["\(observation.day.timeIntervalSince1970)|\(observation.dimension.rawValue)"] = observation
        }
        return Dictionary(grouping: Array(unique.values), by: \.dimension).compactMap { dimension, values -> PersonaTraitState? in
            let independent = independentDays(values)
            let weights = Dictionary(grouping: independent, by: \.value).mapValues { proofs in
                proofs.map { $0.confidence * pow(0.9, Double(age($0.day))) }
            }
            let total = weights.values.flatMap { $0 }.reduce(0, +)
            let candidates = Dictionary(grouping: independent, by: \.value).map { value, proofs -> PersonaTraitState in
                let weighted = weights[value] ?? []
                let last = proofs.map(\.day).max() ?? today
                let strength = age(last) > 14 ? 0 : 1 - weighted.reduce(1) { $0 * (1 - $1) }
                var state = PersonaTraitState(dimension: dimension, value: value, strength: strength,
                    observationDays: proofs.count, evidenceIDs: proofs.sorted { $0.day > $1.day }.map(\.id), updatedAt: last)
                state.dominance = total > 0 ? weighted.reduce(0, +) / total : 0
                state.dimensionDays = independent.count
                return state
            }
            return candidates.sorted {
                if $0.strength != $1.strength { return $0.strength > $1.strength }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.value < $1.value
            }.first
        }.sorted { $0.strength == $1.strength ? $0.dimension.rawValue < $1.dimension.rawValue : $0.strength > $1.strength }
    }

    /// The same source record carried across several daily reviews is one observation, not several.
    /// Keeps the newest day for each source set.
    static func independentDays(_ values: [PersonaTraitObservation]) -> [PersonaTraitObservation] {
        var claimed: Set<UUID> = [], result: [PersonaTraitObservation] = []
        for observation in values.sorted(by: { $0.day > $1.day }) {
            let sources = Set(observation.sourceIDs ?? [])
            if !sources.isEmpty && sources.isSubset(of: claimed) { continue }
            claimed.formUnion(sources); result.append(observation)
        }
        return result
    }
}
