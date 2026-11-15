import Foundation

public enum PersonaPersonalization {
    /// Tentative presentation hints only: never evidence of an accomplishment, a task or a diagnosis.
    public static func text(in state: RecallState, now: Date = .now) -> String {
        guard state.personaProfileSettings.enabled, state.personaProfileSettings.personalizesResponses,
              state.memoryKnowledgeSettings.referencesEnabled else { return "" }
        var live = state; live.reconcilePersonaProfile(now: now)
        let usable: Set<PersonaDimension> = [.communicationStyle, .decisionStyle, .learningStyle, .stressResponse, .workPace]
        let traits = live.personaTraits.filter { $0.isConfirmed && usable.contains($0.dimension) }.prefix(3)
        guard !traits.isEmpty else { return "" }
        let lines = traits.map { "- " + $0.dimension.valueTitle($0.value) }
        return """
        近期行为观察（暂定，低优先级，仅用于相关回答的组织方式或可选建议）：
        \(lines.joined(separator: "\n"))
        当次要求与用户明确表达的偏好优先；不相关时忽略这些观察。不能将观察作为事实、成就、待办或截止时间的证据，不据此新建、完成或安排提醒，不在工作周报正文中插入人格分析，不作心理诊断。
        """
    }
}
