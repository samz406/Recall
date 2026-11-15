import Foundation
import RecallKit

extension RecallLayoutPreviews {
    static let personaQuote = "我先系统查阅资料并核对日志，再逐项验证测试结果；连续三小时专注同一任务，没有切换。"
    static func personaFixtureState(seeded: Bool = false) -> RecallState {
        var state = RecallState(); state.privacy.cloudUseEnabled = true
        state.personaProfileVersion = 1
        state.llmConfiguration = LLMConfiguration(provider: .openAICompatible, baseURLString: "https://synthetic.invalid/v1", model: "synthetic")
        state.llmConfiguration.credentialReference = UUID().uuidString
        for offset in 0..<3 {
            let day = Calendar.current.startOfDay(for: .now).addingTimeInterval(-Double(offset) * 86_400)
            let record = CaptureRecord(eventTemplate: .manualMoment, createdAt: day, sourceAppName: "Synthetic Notes",
                contentHash: "synthetic-persona-\(offset)", ocrText: personaQuote, textOrigin: .userInput)
            var summary = DailySummary(day: day, content: "合成回顾", sourceCaptureIDs: [record.id], todos: [], generationKind: .cloud)
            summary.ledger = [DailyMatterLedgerEntry(topic: "合成验证", kind: .matter, status: "completed", section: "progress",
                title: "本人查阅资料并逐项验证", detail: personaQuote, ownedByUser: true,
                quotes: [DailyLedgerQuote(text: personaQuote, sourceIDs: [record.id], speaker: "user")], evidenceIDs: [record.id], occurredAt: day)]
            state.captures.append(record); state.dailySummaries.append(summary)
        }
        state.reconcilePersonaProfile()
        if seeded {
            for summary in state.dailySummaries {
                for (dimension, value) in [(PersonaDimension.decisionStyle, "cautious_verifying"), (.learningStyle, "systematic_research"), (.workPace, "deep_focus")] {
                    var observation = PersonaTraitObservation(dimension: dimension, value: value, evidenceQuote: personaQuote, confidence: 0.8, day: summary.day, sourceDailySummaryID: summary.id)
                    observation.sourceVersion = state.personaSourceVersion(summary)
                    observation.evidenceID = PersonaInsightEngine().evidence(for: summary).first?.id
                    state.personaTraitObservations.append(observation)
                }
            }
            for i in state.personaRefreshJobs.indices { state.personaRefreshJobs[i].status = .completed }
            state.reconcilePersonaProfile()
        }
        return state
    }
    private actor PersonaPreviewResponder: LLMResponding {
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            let proof = try JSONDecoder().decode([PersonaInsightEngine.Evidence].self, from: Data(request.context[0].ocrText.utf8))[0]
            let rows: [[String: Any]] = [("decisionStyle", "cautious_verifying"), ("learningStyle", "systematic_research"), ("workPace", "deep_focus")].map {
                ["dimension": $0.0, "value": $0.1, "evidenceID": proof.id, "evidence": proof.quote, "confidence": 0.8]
            }
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: ["traits": rows]), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    @MainActor static func verifyPersonaProfileActions() async throws {
        enum Failure: Error { case failed(String) }
        let model = try RecallAppModel(previewState: personaFixtureState(), personaResponder: PersonaPreviewResponder())
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        _ = await model.updatePersonaProfile(.enabled(true))
        for _ in 0..<400 {
            if !model.isRefreshingPersonaProfile { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard model.state.confirmedPersonaTraits.count == 3 else { throw Failure.failed("真实入口未累积三个独立观察日") }
        model.refreshPersonaProfileIfNeeded()
        guard !model.isRefreshingPersonaProfile else { throw Failure.failed("空队列仍初始化模型连接或凭据访问") }
        _ = await model.updatePersonaProfile(.personalizes(false))
        guard PersonaPersonalization.text(in: model.state).isEmpty else { throw Failure.failed("暂停参考未生效") }
        let evidence = model.state.personaTraitObservations.first!
        _ = await model.updatePersonaProfile(.reject([evidence.id]))
        guard !model.state.personaTraitObservations.contains(where: { $0.id == evidence.id }) else { throw Failure.failed("撤回证据未生效") }
        _ = await model.updatePersonaProfile(.clear)
        let reopened = try FileMemoryStore(storage: model.storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
        let after = await reopened.snapshot()
        guard after.personaTraitObservations.isEmpty, !after.personaProfileSettings.enabled, model.state.personaRefreshJobs.isEmpty else { throw Failure.failed("清空停止未持久化") }
        print("PASS: native persona actions use an independent responder, accumulate independent dates, pause personalization, retract evidence skip empty-queue credential access and persist clear-and-stop across restart")
    }
}
