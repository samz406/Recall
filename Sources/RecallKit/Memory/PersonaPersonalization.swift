import Foundation

public enum PersonaPersonalization {
    /// Tentative presentation hints only: never evidence of an accomplishment, a task or a diagnosis.
    /// Injects how to adapt, not who the user is, and yields to anything the user stated explicitly.
    public static func text(in state: RecallState, now: Date = .now) -> String {
        guard state.personaProfileSettings.enabled, state.personaProfileSettings.personalizesResponses,
              state.memoryKnowledgeSettings.referencesEnabled else { return "" }
        let explicit = state.memoryKnowledge.claims.filter {
            $0.kind.isPersonal && $0.usable(at: now) && state.memoryKnowledgeSettings.references($0)
        }.map(\.content)
        let slots = Set(explicit.compactMap(MemoryPersonalization.preferenceSlot))
        let lines = state.confirmedPersonaTraits(now: now).filter { trait in
            guard slots.isDisjoint(with: trait.dimension.preferenceSlots) else { return false }
            // A kept observation is already an explicit preference; do not repeat or contradict it.
            let guidance = trait.dimension.allowedValues.compactMap { trait.dimension.responseGuidance($0) } + [trait.responseGuidance].compactMap { $0 }
            return !explicit.contains { content in guidance.contains(where: content.contains) }
        }.prefix(3).compactMap(\.responseGuidance)
        guard !lines.isEmpty else { return "" }
        return """
        回答组织方式参考（来自近期行为观察，暂定、低优先级，仅在相关时采用）：
        \(lines.map { "- " + $0 }.joined(separator: "\n"))
        当次要求与用户明确表达的偏好优先；不相关时忽略。只调整回答的组织方式，不向用户复述或评价其性格，不能将观察作为事实、成就、待办或截止时间的证据，不据此新建、完成或安排提醒，不作心理诊断。
        """
    }
}
