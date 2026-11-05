import Foundation
import RecallKit

/// Scripted model decisions for the cloud 问一问 loop. No network and no real screen text.
@MainActor
enum AskAgentVerification {
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }

    static func run() async throws {
        try streamLines()
        try await directAnswerIncludesVerification()
        try await toolsThenAnswerDropFakeCitations()
        try await unauthorizedReadsStayLocal()
        try await tooManyCallsForceAnAnswer()
        try await roundCapForcesAnAnswer()
        try await budgetForcesAnAnswer()
        try await invalidPlanFallsBack()
        try await deletedSourceVoidsTheAnswer()
        try await cancellationStopsTheRequest()
        print("PASS: 10 ask-agent scenarios (stream, direct answer, tools, refusal, budget, fallback, deletion, cancellation)")
    }

    private static func streamLines() throws {
        var text = ""
        let first = "data: " + json(["choices": [["delta": ["content": "你"]]]])
        let second = "data: " + json(["choices": [["delta": ["content": "好"]]]])
        try expect(!ModelStreamDecoder.consume(first, into: &text), "流式片段被当成结束")
        _ = ModelStreamDecoder.consume(second, into: &text)
        try expect(text == "你好", "OpenAI 兼容流没有拼上文字")
        try expect(ModelStreamDecoder.consume("data: [DONE]", into: &text), "OpenAI 结束标记没有收束")
        var anthropic = ""
        let delta = "data: " + json(["type": "content_block_delta", "delta": ["type": "text_delta", "text": "周"]])
        _ = ModelStreamDecoder.consume(delta, into: &anthropic)
        try expect(anthropic == "周", "Anthropic 兼容流没有取出文字")
        let stop = "data: " + json(["type": "message_stop"])
        try expect(ModelStreamDecoder.consume(stop, into: &anthropic), "Anthropic 结束标记没有收束")
    }

    private static func directAnswerIncludesVerification() async throws {
        let (storage, store, capture) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let before = await store.snapshot().memoryKnowledge.updatedAt
        let script = ScriptedAskModel { request in
            let body = #"{"answer":"已经记下 AtlasScopeToken","citations":[""# + capture.id.uuidString + #""]}"#
            return LLMAnswer(content: body, citedCaptureIDs: [])
        }
        var steps: [String] = []
        let answer = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script, onStep: { name, _ in steps.append(name) })
        let purposes = await script.recorded().map(\.purpose)
        try expect(purposes == [.chatPlanning, .answerVerification], "直接回答应只增加一次事实核验")
        try expect(answer.content.contains("AtlasScopeToken") && answer.citations == [capture.id], "第一轮回答没有保留已出现的来源")
        let after = await store.snapshot().memoryKnowledge.updatedAt
        try expect(after == before, "提问重算了记忆账本")
        try expect(steps.contains("analysis") && steps.allSatisfy { !$0.contains("AtlasScopeToken") }, "耗时日志写入了问题原文")
    }

    private static func toolsThenAnswerDropFakeCitations() async throws {
        let (storage, store, capture) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let fake = UUID()
        let script = ScriptedAskModel { request in
            if request.purpose == .chatPlanning, !request.question.contains("已读取的工具结果") {
                return LLMAnswer(content: #"{"calls":[{"tool":"search_records","args":{"query":"AtlasScopeToken"}}]}"#, citedCaptureIDs: [])
            }
            let body = #"{"answer":"AtlasScopeToken 已找到 \#(fake.uuidString)","citations":[""# + capture.id.uuidString + #"",""# + fake.uuidString + #""]}"#
            return LLMAnswer(content: body, citedCaptureIDs: [])
        }
        let answer = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script)
        try expect(answer.citations == [capture.id] && !answer.content.contains(fake.uuidString), "伪造的来源仍留在回答里")
        let purposes = await script.recorded().map(\.purpose)
        try expect(purposes == [.chatPlanning, .chatPlanning, .answerVerification], "检索后的回答多走了最终流式请求")
    }

    private static func unauthorizedReadsStayLocal() async throws {
        let (storage, store, visible) = try await fixture("AtlasScopeToken 可见内容")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let hidden = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "合成", sourceBundleIdentifier: "example.visible",
            contentHash: UUID().uuidString, ocrText: "NOT-MINE-SECRET-TOKEN", textOrigin: .userInput)
        let excluded = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "合成", sourceBundleIdentifier: "example.secret",
            contentHash: UUID().uuidString, ocrText: "EXCLUDED-SECRET-TOKEN", textOrigin: .userInput)
        try await store.addCapture(hidden)
        try await store.addCapture(excluded)
        try await store.saveMatterCorrection(MatterCorrection(evidenceIDs: [hidden.id], kind: .notMine))
        var privacy = await store.snapshot().privacy
        privacy.excludedBundleIdentifiers.insert("example.secret")
        privacy.cloudUseEnabled = true
        try await store.updatePrivacy(privacy)
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .openAICompatible, baseURLString: "https://example.test/v1", model: "test", apiKey: "test-key"))
        let review = DailySummary(day: .now, content: "REVIEW-SECRET-TOKEN", sourceCaptureIDs: [visible.id], todos: [], generationKind: .localFallback)
        try await store.upsertDailySummary(review)
        let unknown = UUID()
        let script = ScriptedAskModel { request in
            if request.purpose != .chatPlanning || request.question.contains("已读取的工具结果") {
                return LLMAnswer(content: #"{"answer":"没有这些内容","citations":[]}"#, citedCaptureIDs: [])
            }
            let calls: [String: Any] = ["calls": [
                ["tool": "read_records", "args": ["ids": [hidden.id.uuidString, excluded.id.uuidString, unknown.uuidString]]],
                ["tool": "get_daily_reviews", "args": ["from": "2020-01-01", "to": "2020-03-01"]]
            ]]
            return LLMAnswer(content: json(calls), citedCaptureIDs: [])
        }
        _ = try await MemoryAssistant(store: store).ask("读取指定记录", model: script)
        let toolText = await script.recorded().dropFirst().map(\.question).joined(separator: "\n")
        try expect(!toolText.contains("NOT-MINE-SECRET-TOKEN") && !toolText.contains("EXCLUDED-SECRET-TOKEN") && !toolText.contains("REVIEW-SECRET-TOKEN"), "越权读取把正文交了出去")
        try expect(toolText.contains("已拒绝"), "越权请求没有被拒绝")
    }

    private static func tooManyCallsForceAnAnswer() async throws {
        let (storage, store, capture) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let plan = json(["calls": (0..<7).map { _ in ["tool": "read_records", "args": ["ids": [capture.id.uuidString]]] }])
        let script = ScriptedAskModel { request in
            if request.purpose == .chatPlanning { return LLMAnswer(content: plan, citedCaptureIDs: []) }
            return LLMAnswer(content: "已根据现有材料回答", citedCaptureIDs: [])
        }
        var tools: [String] = []
        let answer = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script, onStep: { name, _ in if name.hasPrefix("tool:") { tools.append(name) } })
        let purposes = await script.recorded().map(\.purpose)
        try expect(tools.count == 6 && purposes.filter { $0 == .chatPlanning }.count == 1 && purposes.last == .answerVerification, "超过每轮调用上限后仍继续决定")
        try expect(answer.content.contains("AtlasScopeToken"), "强制回答没有写回会话")
    }

    private static func roundCapForcesAnAnswer() async throws {
        let (storage, store, _) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let script = ScriptedAskModel { request in
            if request.purpose == .chatPlanning {
                return LLMAnswer(content: #"{"calls":[{"tool":"list_days","args":{"from":"2026-11-01","to":"2026-11-01"}}]}"#, citedCaptureIDs: [])
            }
            return LLMAnswer(content: "轮数到了，按已有材料回答", citedCaptureIDs: [])
        }
        var tools: [String] = []
        _ = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script, onStep: { name, _ in if name.hasPrefix("tool:") { tools.append(name) } }, limits: AskLimits(maxRounds: 2))
        let purposes = await script.recorded().map(\.purpose)
        try expect(purposes.filter { $0 == .chatPlanning }.count == 2 && tools.count == 2 && purposes.last == .answerVerification, "超过轮数后仍继续要工具")
    }

    private static func budgetForcesAnAnswer() async throws {
        let long = "HEAD-TOKEN " + String(repeating: "字", count: 500) + " TAIL-SECRET"
        let (storage, store, capture) = try await fixture(long)
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let script = ScriptedAskModel { request in
            if request.purpose == .chatPlanning {
                return LLMAnswer(content: json(["calls": [["tool": "read_records", "args": ["ids": [capture.id.uuidString]]]]]), citedCaptureIDs: [])
            }
            return LLMAnswer(content: "材料已截断后的回答", citedCaptureIDs: [])
        }
        _ = try await MemoryAssistant(store: store).ask("HEAD-TOKEN", model: script, limits: AskLimits(maxResultCharacters: 80))
        let recorded = await script.recorded()
        let sent = recorded.filter { $0.purpose == .chat || $0.purpose == .answerVerification }.map { $0.question + ($0.supplementaryContext ?? "") + $0.context.map(\.ocrText).joined() }.joined()
        try expect(!sent.contains("TAIL-SECRET"), "超出字数预算后仍把后文发给模型")
        try expect(recorded.last?.purpose == .answerVerification, "裁剪后的原文片段未进入事实核验")
    }

    private static func invalidPlanFallsBack() async throws {
        let (storage, store, _) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let script = ScriptedAskModel { request in
            if request.purpose == .chatPlanning { return LLMAnswer(content: "不是 JSON", citedCaptureIDs: []) }
            return LLMAnswer(content: "回退后的摘录", citedCaptureIDs: [])
        }
        let answer = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script)
        try expect(answer.content.contains("AtlasScopeToken"), "格式错误没有退回原来的回答")
        let purposes = await script.recorded().map(\.purpose)
        try expect(purposes.contains(.chatPlanning) && purposes.contains(.chat), "回退没有再走原来的回答请求")
    }

    private static func deletedSourceVoidsTheAnswer() async throws {
        let (storage, store, capture) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let script = ScriptedAskModel { request in
            _ = try await store.deleteCapture(id: capture.id)
            let body = #"{"answer":"AtlasScopeToken 还在","citations":[""# + capture.id.uuidString + #""]}"#
            return LLMAnswer(content: body, citedCaptureIDs: [])
        }
        do {
            _ = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script)
            throw Failure(message: "回答期间删除来源后仍然保存了回答")
        } catch let error as LLMError {
            guard case let .serviceError(message) = error else { throw Failure(message: "删除来源后的错误类型不对") }
            try expect(message.contains("删除") || message.contains("更正"), "删除来源后没有作废这次回答")
        }
    }

    private static func cancellationStopsTheRequest() async throws {
        let (storage, store, _) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let script = ScriptedAskModel { _ in
            try await Task.sleep(for: .seconds(30))
            return LLMAnswer(content: #"{"answer":"太慢","citations":[]}"#, citedCaptureIDs: [])
        }
        let task = Task { try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script) }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do {
            _ = try await task.value
            throw Failure(message: "取消后仍然返回了回答")
        } catch is CancellationError {}
    }

    private static func fixture(_ text: String) async throws -> (RecallStorage, FileMemoryStore, CaptureRecord) {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-ask-agent-" + UUID().uuidString))
        let store = try verificationStore(storage: storage)
        let capture = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "合成验证", sourceBundleIdentifier: "example.ask-agent",
            contentHash: UUID().uuidString, ocrText: text, textOrigin: .userInput)
        try await store.addCapture(capture)
        var privacy = await store.snapshot().privacy
        privacy.cloudUseEnabled = true
        try await store.updatePrivacy(privacy)
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .openAICompatible, baseURLString: "https://example.test/v1", model: "test", apiKey: "test-key"))
        return (storage, store, capture)
    }

}

private func json(_ object: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

private actor ScriptedAskModel: LLMResponding {
    private let handler: @Sendable (LLMRequest) async throws -> LLMAnswer
    private var stored: [LLMRequest] = []
    init(_ handler: @escaping @Sendable (LLMRequest) async throws -> LLMAnswer) { self.handler = handler }
    func answer(to request: LLMRequest) async throws -> LLMAnswer {
        stored.append(request)
        if request.purpose == .answerVerification, let source = request.context.first {
            let quote = source.ocrText.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            let claim = AnswerGrounding.Claim(statement: quote, evidence: [.init(sourceID: source.id, quote: quote)])
            let data = try JSONEncoder().encode(["claims": [claim]])
            return LLMAnswer(content: String(decoding: data, as: UTF8.self), citedCaptureIDs: [])
        }
        return try await handler(request)
    }
    func recorded() -> [LLMRequest] { stored }
}
