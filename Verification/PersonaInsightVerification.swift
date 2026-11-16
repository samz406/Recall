import Foundation
import RecallKit

/// Synthetic contracts for provenance, independent dates, deletion races and durable background jobs.
enum PersonaInsightVerification {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(errorDescription: message) } }
    static let quote = "我先系统查阅资料并核对日志，再逐项验证测试结果；连续三小时专注同一任务，没有切换。"
    static func run() async throws {
        try independentDatesAndDecay()
        try evidenceAndAttribution()
        try conservativeArchetypes()
        try await refreshFeedbackAndPersonalization()
        try await restoreHiddenMatch()
        try await failuresResumeAndRegeneration()
        try await deletionAndPrivacyRaces()
        try await cancellationAndCoalescing()
        try await deletionCorrectionsAndWriteFailure()
        try await modelPriority()
        print("PASS: persona independent dates, aging/weak evidence, ownership/quote validation, bounded input, conservative labels, feedback/personalization, retries/restart, regeneration, deletion/privacy/reset races, cancellation/coalescing, write rollback and foreground priority")
    }
    static func independentDatesAndDecay() throws {
        let today = Calendar.current.startOfDay(for: .now)
        func proof(_ offset: Int, _ confidence: Double = 0.8) -> PersonaTraitObservation {
            PersonaTraitObservation(dimension: .workPace, value: "deep_focus", evidenceQuote: quote,
                confidence: confidence, day: today.addingTimeInterval(Double(offset) * 86_400), sourceDailySummaryID: UUID())
        }
        try expect(PersonaProfileEngine.rebuild(from: [proof(0), proof(0), proof(0)]).first?.observationDays == 1, "重复生成同日被算作多个观察日")
        try expect(PersonaProfileEngine.rebuild(from: [proof(-1), proof(0)]).first?.isConfirmed == false, "两日不应确认")
        let observations = [proof(-2), proof(-1), proof(0)]
        try expect(PersonaProfileEngine.rebuild(from: observations).first?.isConfirmed == true, "三个独立日期的强证据未确认")
        try expect(PersonaProfileEngine.rebuild(from: [proof(-2, 0), proof(-1, 0.2), proof(0, 0.5)]).isEmpty, "低置信度被累计成稳定判断")
        try expect(PersonaProfileEngine.rebuild(from: observations, now: today.addingTimeInterval(20 * 86_400)).first?.isConfirmed == false, "没有新观察时旧判断未过期")
        try expect(PersonaProfileEngine.rebuild(from: observations, now: today.addingTimeInterval(32 * 86_400)).isEmpty, "过期窗口仍保留可展示特征")
    }
    static func evidenceAndAttribution() throws {
        var summary = summary(source: CaptureRecord(eventTemplate: .manualMoment, contentHash: "synthetic", ocrText: quote), offset: 0)
        summary.modelOverview = "同事连续四小时专注研究；文章中的人习惯用直觉决策。"
        var other = summary.ledger[0]; other.id = UUID(); other.ownedByUser = false; other.title = "同事的事"
        other.quotes = [DailyLedgerQuote(text: "同事专注研究整个下午", sourceIDs: summary.sourceCaptureIDs, speaker: "other")]
        var reference = other; reference.id = UUID(); reference.ownedByUser = true; reference.kind = .reference
        summary.ledger += [other, reference]
        let engine = PersonaInsightEngine(), documents = engine.evidence(for: summary)
        let text = engine.text(documents)
        try expect(!text.contains("同事") && !text.contains("文章中的人"), "混入他人/资料或概览")
        let id = documents[0].id
        func parse(_ raw: String) throws -> [PersonaTraitObservation] {
            try engine.observations(from: raw, evidence: documents, day: summary.day, dailySummaryID: summary.id, sourceVersion: "v1")
        }
        let valid = try parse("{\"traits\":[{\"dimension\":\"workPace\",\"value\":\"deep_focus\",\"evidenceID\":\"\(id)\",\"evidence\":\"连续三小时专注同一任务\",\"confidence\":0.8}]}")
        try expect(valid.count == 1, "有效逐字本人证据被拒绝")
        try expect(try parse("{\"traits\":[]}").isEmpty, "空观察未被当作有效结果")
        for raw in ["{broken", "{\"traits\":[{\"dimension\":\"workPace\",\"value\":\"deep_focus\",\"evidenceID\":\"other\",\"evidence\":\"连续三小时专注同一任务\",\"confidence\":0.8}]}"] {
            do { _ = try parse(raw); throw Failure(errorDescription: "无效输出被静默吞成无观察") } catch is PersonaInsightError { }
        }
        summary.ledger = []; summary.items = [DailySummaryItem(section: .progress, title: "没有归属的旧内容", detail: quote)]
        try expect(engine.evidence(for: summary).isEmpty, "旧格式无归属内容进入推断")
        let own = documents[0]
        summary.ledger = (0..<100).map { index in
            DailyMatterLedgerEntry(topic: "合成", kind: .matter, status: "completed", section: "progress", title: own.title,
                detail: String(repeating: "合成", count: 400), ownedByUser: true,
                quotes: [DailyLedgerQuote(text: own.quote, sourceIDs: own.sourceIDs, speaker: "user")], evidenceIDs: own.sourceIDs, occurredAt: nil)
        }
        var oldState = RecallState(); oldState.captures = [CaptureRecord(eventTemplate: .manualMoment, contentHash: "old", ocrText: quote)]
        // Test only the temporal boundary; the source need not be sent to a model.
        summary.day = Calendar.current.startOfDay(for: .now).addingTimeInterval(-40 * 86_400)
        summary.sourceCaptureIDs = oldState.captures.map(\.id); oldState.dailySummaries = [summary]
        oldState.reconcilePersonaProfile()
        try expect(oldState.pendingPersonaRefresh.isEmpty, "过期回顾被排队外发")
        let bounded = engine.evidence(for: summary)
        try expect(bounded.count <= 16 && bounded.reduce(0, { $0 + $1.title.count + $1.detail.count + $1.quote.count }) <= 6_000, "输入预算未生效")
    }
    static func conservativeArchetypes() throws {
        func trait(_ dimension: PersonaDimension, _ value: String) -> PersonaTraitState {
            PersonaTraitState(dimension: dimension, value: value, strength: 0.9, observationDays: 4, evidenceIDs: [])
        }
        let full = [trait(.decisionStyle, "cautious_verifying"), trait(.learningStyle, "systematic_research"), trait(.stressResponse, "breakdown_planning"), trait(.valueFocus, "quality")]
        try expect(PersonaProfileEngine.match(Array(full.prefix(2))) == nil, "少量支撑维度给出了人格标签")
        try expect(PersonaProfileEngine.match(full)?.archetypeID == "meticulous-planner", "充分支持的形象未匹配")
        try expect(PersonaProfileEngine.match(full, excludingArchetypeIDs: ["meticulous-planner"]) == nil, "排除后不应强行换标签")
        let conflict = Array(full.prefix(3)) + [trait(.valueFocus, "innovation")]
        try expect(PersonaProfileEngine.match(conflict) == nil, "矛盾证据被忽略")
    }
    static func summary(source: CaptureRecord, offset: Int) -> DailySummary {
        let day = Calendar.current.startOfDay(for: .now).addingTimeInterval(-Double(offset) * 86_400)
        var result = DailySummary(day: day, createdAt: day.addingTimeInterval(72_000), content: "合成回顾", sourceCaptureIDs: [source.id], todos: [], generationKind: .cloud)
        result.ledger = [DailyMatterLedgerEntry(topic: "合成验证", kind: .matter, status: "completed", section: "progress", title: "本人核对资料并验证结果", detail: quote,
            ownedByUser: true, quotes: [DailyLedgerQuote(text: quote, sourceIDs: [source.id], speaker: "user")], evidenceIDs: [source.id], occurredAt: day)]
        return result
    }
    static func fixture(days: Int = 3) throws -> (store: FileMemoryStore, storage: RecallStorage) {
        var state = RecallState(); state.privacy.cloudUseEnabled = true
        state.llmConfiguration = LLMConfiguration(provider: .openAICompatible, baseURLString: "https://synthetic.invalid/v1", model: "synthetic")
        state.llmConfiguration.credentialReference = UUID().uuidString
        for offset in 0..<days {
            let source = CaptureRecord(eventTemplate: .manualMoment, createdAt: Date.now.addingTimeInterval(-Double(offset) * 86_400),
                sourceAppName: "Synthetic Notes", sourceBundleIdentifier: "synthetic.persona", contentHash: "synthetic-\(offset)", ocrText: quote, textOrigin: .userInput)
            state.captures.append(source); state.dailySummaries.append(summary(source: source, offset: offset))
        }
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("persona-" + UUID().uuidString))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: storage.stateURL)
        return (try FileMemoryStore(storage: storage, deferMaintenance: true, credentials: InMemoryCredentialStore()), storage)
    }
    actor Model: LLMResponding {
        var mode: String; var requests: [LLMRequest] = []; var waiting = false
        var waiter: CheckedContinuation<Void, Never>?
        init(_ mode: String = "valid") { self.mode = mode }
        func setMode(_ value: String) { mode = value }
        func isWaiting() -> Bool { waiting }
        func count() -> Int { requests.count }
        func release() { waiting = false; waiter?.resume(); waiter = nil }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            requests.append(request)
            if mode == "pause" { waiting = true; await withCheckedContinuation { waiter = $0 } }
            if mode == "failure" { throw URLError(.notConnectedToInternet) }
            if mode == "malformed" { return LLMAnswer(content: "{broken", citedCaptureIDs: []) }
            if mode == "empty" { return LLMAnswer(content: "{\"traits\":[]}", citedCaptureIDs: []) }
            let proof = try JSONDecoder().decode([PersonaInsightEngine.Evidence].self, from: Data(request.context[0].ocrText.utf8))[0]
            let pairs = mode == "planner"
                ? [("decisionStyle", "cautious_verifying"), ("learningStyle", "systematic_research"), ("stressResponse", "breakdown_planning")]
                : [("decisionStyle", "cautious_verifying"), ("learningStyle", "systematic_research"), ("workPace", "deep_focus")]
            let entries: [[String: Any]] = pairs.map { dimension, value in
                ["dimension": dimension, "value": value, "evidenceID": proof.id, "evidence": proof.quote, "confidence": 0.8]
            }
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: ["traits": entries]), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    static func drain(_ store: FileMemoryStore, _ responder: Model) async throws {
        for _ in 0..<40 { let work = try await store.refreshPersonaProfile(responder: responder); if !work { return } }
        throw Failure(errorDescription: "个人观察队列未按上限结束")
    }
    static func wait(_ model: Model) async throws {
        for _ in 0..<200 { if await model.isWaiting() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw Failure(errorDescription: "模型未进入等待状态")
    }
    static func refreshFeedbackAndPersonalization() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let responder = Model(); try await drain(f.store, responder)
        var state = await f.store.snapshot()
        try expect(state.confirmedPersonaTraits.count == 3, "三天观察未在完整流程生效")
        try expect(!PersonaPersonalization.text(in: state).isEmpty, "未接入个性化上下文")
        try expect(PersonalMemoryContext.text(in: state, question: "给些建议").contains("当次要求与用户明确表达的偏好优先"), "缺少明确要求优先约束")
        var explicit = state
        let directive = MemoryDirective.parse("记住：以后回答详细一点，说明验证过程")!
        explicit.captures.append(CaptureRecord(eventTemplate: .manualMoment, sourceAppName: "明确约定", contentHash: "synthetic-explicit", ocrText: directive.content, textOrigin: .userInput, memoryDirective: directive))
        explicit.memoryKnowledge = MemoryKnowledgeEngine().reconcile(explicit, force: true)
        let context = PersonalMemoryContext.text(in: explicit, question: "给些建议")
        try expect(context.contains(directive.content), "明确偏好没有进入实际共用上下文")
        if let preferred = context.range(of: directive.content), let inferred = context.range(of: "近期行为观察") {
            try expect(preferred.lowerBound < inferred.lowerBound, "自动观察排在明确偏好之前")
        } else { throw Failure(errorDescription: "个性化上下文缺失") }
        var paused = state; paused.memoryKnowledgeSettings.referenceInChat = false
        try expect(PersonaPersonalization.text(in: paused).isEmpty, "总参考开关未约束自动观察")
        try await f.store.dismissPersonaTrait(.workPace)
        state = await f.store.snapshot(); try expect(!state.personaTraits.contains { $0.dimension == .workPace }, "停用维度仍显示")
        try await f.store.resumePersonaTrait(.workPace)
        state = await f.store.snapshot(); try expect(state.confirmedPersonaTraits.contains { $0.dimension == .workPace }, "恢复未重建已有依据")
        let evidence = state.personaTraitObservations.first { $0.dimension == .workPace }!
        try await f.store.rejectPersonaEvidence([evidence.id])
        state = await f.store.snapshot(); try expect(!state.confirmedPersonaTraits.contains { $0.dimension == .workPace }, "纠正后仍沿用三日判断")
        try await f.store.setPersonaPersonalization(false)
        state = await f.store.snapshot(); try expect(PersonaPersonalization.text(in: state).isEmpty, "暂停参考后仍发送推断")
        try await f.store.clearPersonaProfile()
        state = await f.store.snapshot(); try expect(state.personaTraitObservations.isEmpty && state.personaMatchHistory.isEmpty && !state.personaProfileSettings.enabled, "清空后残留历史或继续排队")
        try await f.store.clearPersonaProfile(rebuild: true)
        state = await f.store.snapshot(); try expect(state.pendingPersonaRefresh.count == 3, "重建未对已有每日回顾补齐")
    }
    static func restoreHiddenMatch() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        try await drain(f.store, Model("planner"))
        let before = await f.store.snapshot()
        guard let label = before.personaMatch else { throw Failure(errorDescription: "匹配恢复夹具没有形成形象") }
        try await f.store.dismissPersonaMatch()
        let hidden = await f.store.snapshot()
        try expect(hidden.personaMatch == nil, "同一依据立即换了另一个标签")
        try await f.store.restorePersonaMatches()
        let restored = await f.store.snapshot()
        try expect(restored.personaMatch?.archetypeID == label.archetypeID, "被收起的形象无法恢复")
    }
    static func failuresResumeAndRegeneration() async throws {
        let f = try fixture(days: 2); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Model("malformed"); _ = try await f.store.refreshPersonaProfile(responder: model)
        var state = await f.store.snapshot()
        try expect(state.personaRefreshJobs.first?.status == .failed && state.personaTraitObservations.isEmpty, "格式错误未保留失败检查点")
        await model.setMode("valid"); _ = try await f.store.refreshPersonaProfile(responder: model)
        state = await f.store.snapshot(); try expect(state.personaTraitObservations.count == 3, "失败阻止了其他日期处理")
        let reopened = try FileMemoryStore(storage: f.storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
        _ = try await reopened.refreshPersonaProfile(responder: model, now: .now.addingTimeInterval(31))
        state = await reopened.snapshot(); try expect(state.personaRefreshJobs.allSatisfy { $0.status == .completed }, "重启后没有恢复到期重试")
        // Replace one saved day with a new review ID, exactly as regeneration does.
        var archived = state
        let old = archived.dailySummaries[0]
        var replacement = old; replacement.id = UUID(); replacement.createdAt = .now
        archived.dailySummaries[0] = replacement
        archived.reconcilePersonaProfile()
        try expect(!archived.personaTraitObservations.contains { $0.sourceDailySummaryID == old.id }, "重新生成后旧观察仍累计")
        try expect(archived.personaRefreshJobs.contains { $0.summaryID == replacement.id && $0.status == .queued }, "新版本没有进入独立检查点")
        await model.setMode("empty")
        let g = try fixture(days: 1); defer { try? FileManager.default.removeItem(at: g.storage.rootURL) }
        _ = try await g.store.refreshPersonaProfile(responder: model)
        let empty = await g.store.snapshot()
        try expect(empty.personaRefreshJobs.first?.status == .insufficientEvidence, "有效无证据结果被当作故障重试")
    }
    static func deletionAndPrivacyRaces() async throws {
        for scenario in ["delete", "privacy", "clear", "exclude"] {
            let f = try fixture(days: 1); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
            let model = Model("pause"), state = await f.store.snapshot()
            let task = Task { try await f.store.refreshPersonaProfile(responder: model) }
            try await wait(model)
            switch scenario {
            case "delete": try await f.store.deleteDailySummary(id: state.dailySummaries[0].id)
            case "clear": try await f.store.clearPersonaProfile()
            default:
                var privacy = state.privacy
                if scenario == "privacy" { privacy.cloudUseEnabled = false } else { privacy.excludedBundleIdentifiers.insert("synthetic.persona") }
                try await f.store.updatePrivacy(privacy)
            }
            await model.release(); _ = try await task.value
            let after = await f.store.snapshot()
            try expect(after.personaTraitObservations.isEmpty && after.personaMatch == nil, "\(scenario) 后迟到的结果被保存")
        }
    }
    static func cancellationAndCoalescing() async throws {
        let f = try fixture(days: 1); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Model("pause"), task = Task { try await f.store.refreshPersonaProfile(responder: model) }
        try await wait(model)
        let duplicate = try await f.store.refreshPersonaProfile(responder: model)
        let calls = await model.count()
        try expect(!duplicate && calls == 1, "并发调用重复发出了模型请求")
        task.cancel()
        do { _ = try await task.value; throw Failure(errorDescription: "取消未中断调用") } catch is CancellationError { }
        var state = await f.store.snapshot(); try expect(state.pendingPersonaRefresh.count == 1, "取消丢掉当天检查点")
        await model.release(); await model.setMode("valid")
        try await drain(f.store, model); state = await f.store.snapshot()
        try expect(state.personaRefreshJobs.first?.status == .completed, "取消后无法继续")
    }
    static func deletionCorrectionsAndWriteFailure() async throws {
        for scenario in ["delete", "exclude", "correction", "write"] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
            try await drain(f.store, Model())
            let before = await f.store.snapshot()
            if scenario == "delete" {
                _ = try await f.store.deleteCapture(id: before.captures[0].id)
            } else if scenario == "correction" {
                try await f.store.saveMatterCorrection(MatterCorrection(evidenceIDs: [before.captures[0].id], kind: .notMine))
            } else if scenario == "exclude" {
                var privacy = before.privacy; privacy.excludedBundleIdentifiers.insert("synthetic.persona")
                try await f.store.updatePrivacy(privacy)
            } else {
                let backup = f.storage.rootURL.appendingPathComponent("saved.json")
                try FileManager.default.moveItem(at: f.storage.stateURL, to: backup)
                try FileManager.default.createDirectory(at: f.storage.stateURL, withIntermediateDirectories: false)
                do { try await f.store.clearPersonaProfile(); throw Failure(errorDescription: "保存故障未传播") } catch is Failure { throw Failure(errorDescription: "写入失败测试未触发") } catch { }
                let after = await f.store.snapshot()
                try expect(after.personaTraitObservations == before.personaTraitObservations && after.personaProfileSettings.enabled, "写失败没有恢复原观察与设置")
                continue
            }
            let after = await f.store.snapshot()
            try expect(after.confirmedPersonaTraits.isEmpty && after.personaMatchHistory.isEmpty, "来源撤回后残留确认判断/历史")
            let reopened = try FileMemoryStore(storage: f.storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
            let restored = await reopened.snapshot()
            try expect(restored.confirmedPersonaTraits.isEmpty, "重启恢复了删除的判断")
        }
    }
    static func modelPriority() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PersonaPriorityProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        PersonaPriorityProtocol.reset()
        let client = CompatibleLLM(configuration: LLMConfiguration(provider: .openAICompatible, baseURLString: "https://synthetic.invalid/v1", model: "synthetic"), apiKey: "synthetic-test-only", session: session)
        let background = Task { try await client.answer(to: LLMRequest(question: "synthetic background", context: [], purpose: .personaInsight)) }
        defer { background.cancel() }
        for _ in 0..<200 { if PersonaPriorityProtocol.count() > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        try expect(PersonaPriorityProtocol.count() == 1, "后台请求没有进入受控传输")
        let answer = try await client.answer(to: LLMRequest(question: "synthetic foreground", context: [], purpose: .chat))
        try expect(answer.content == "synthetic response", "主动请求等待后台分析")
        do { _ = try await background.value; throw Failure(errorDescription: "主动请求未抢占后台调用") } catch is CancellationError { }
    }
}

private final class PersonaPriorityProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var started = 0
    static func reset() { lock.lock(); started = 0; lock.unlock() }
    static func count() -> Int { lock.lock(); defer { lock.unlock() }; return started }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock(); Self.started += 1; let index = Self.started; Self.lock.unlock()
        if index == 1 { return } // Only the foreground response is released; cancellation must wake the background.
        let data = Data(#"{"choices":[{"message":{"content":"synthetic response"},"finish_reason":"stop"}]}"#.utf8)
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
