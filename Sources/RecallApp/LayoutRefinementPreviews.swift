import SwiftUI
import RecallKit

extension RecallLayoutPreviews {
    /// Synthetic content only; renders the source sheet at its own fitting size.
    @MainActor static func reminderSourcePreview(_ name: String) -> ReminderSourceSheet {
        let manual = name.contains("manual")
        let long = name.hasSuffix("long")
        let missing = name.hasSuffix("missing")
        let multiple = name.hasSuffix("multiple")
        let sentence = RecallLocalization.both("合成验收记录：页面核对完成，后续安排仍需确认。", "Synthetic review record: page checks are complete; the follow-up schedule still needs confirmation.")
        let captures: [CaptureRecord] = manual || missing ? [] : (0..<(multiple ? 3 : 1)).map { index in
            CaptureRecord(eventTemplate: .manualMoment, createdAt: .now.addingTimeInterval(-Double(index * 3_600)),
                sourceAppName: RecallLocalization.both("合成笔记", "Synthetic Notes"), contentHash: "synthetic-source-layout-\(index)",
                ocrText: Array(repeating: sentence, count: multiple ? 12 : 2).joined(separator: "\n"), textOrigin: .userInput)
        }
        let detail = long ? Array(repeating: sentence, count: 45).joined(separator: "\n") : ""
        let reminder = ReminderCandidate(title: RecallLocalization.both("核对合成验收记录与后续安排", "Check the synthetic review records and follow-up schedule"),
            detail: detail, sourceCaptureIDs: captures.map(\.id) + (missing || multiple ? [UUID()] : []),
            confidence: 1, origin: manual ? .manual : .discovered)
        return ReminderSourceSheet(reminder: reminder, captures: captures)
    }

    static func personalMemoryLayoutState(many: Bool = false) -> RecallState {
        var state = personaFixtureState(seeded: true)
        for dimension in [PersonaDimension.decisionStyle, .learningStyle] {
            guard let trait = state.confirmedPersonaTraits.first(where: { $0.dimension == dimension }),
                  let guidance = dimension.responseGuidance(trait.value),
                  let directive = MemoryDirective.parse("记住：以后回答时\(guidance)") else { continue }
            state.captures.append(CaptureRecord(eventTemplate: .manualMoment, sourceAppName: "合成明确约定", contentHash: UUID().uuidString,
                ocrText: directive.content, textOrigin: .userInput, memoryDirective: directive))
        }
        state.memoryKnowledge = MemoryKnowledgeEngine().reconcile(state, force: true)
        if many, let prototype = state.memoryKnowledge.claims.first(where: { $0.kind.isPersonal && $0.usable() }) {
            for index in 0..<23 {
                var claim = prototype
                claim.id = UUID(); claim.key = "synthetic-layout-memory-\(index)"
                claim.content = RecallLocalization.both("合成偏好 \(index + 1)：方案说明应保留适用条件、验证方法和后续安排。较长的内容需要自然换行，便于完整阅读和修改。",
                    "Synthetic preference \(index + 1): keep the applicable conditions, verification steps and follow-up schedule in explanations. Longer memories should wrap naturally and remain easy to read and edit.")
                claim.title = claim.content; claim.scope = .work
                claim.updatedAt = .now.addingTimeInterval(Double(index))
                state.memoryKnowledge.claims.append(claim)
            }
        }
        return state
    }
}
