import Foundation
import RecallKit

/// Exercises the real HTTP adapters without a network or real credentials. The mocked
/// thinking-only/max_tokens response reproduces the former generic invalidResponse error.
enum ModelResponseVerification {
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    private static let valid = #"{"headline":"Atlas 导出验证完成","progress":[{"title":"Atlas 导出验证完成","detail":"分页边界与空值用例通过验证。","evidenceIndices":[1]}],"actions":[],"insights":[]}"#
    private static func source() -> CaptureRecord {
        let now = Date.now
        return CaptureRecord(eventTemplate: .workCheckpoint, createdAt: now, sourceAppName: "合成测试聊天", sourceBundleIdentifier: "example.synthetic",
            windowTitle: "Atlas 导出", contentHash: "synthetic-response-test",
            ocrText: "[聊天·自己] Atlas 导出的分页边界与空值用例已验证通过。", textOrigin: .userInput,
            manualMatter: ManualMatterNote(title: "Atlas 导出验证", detail: "分页边界与空值用例通过验证。", status: .completed, eventAt: now))
    }
    private static func configuration(_ provider: LLMProviderKind) -> LLMConfiguration {
        LLMConfiguration(provider: provider, baseURLString: "https://example.invalid/v1", model: "synthetic-model", apiKey: "verification-placeholder", maxOutputTokens: 1_000)
    }
    private static func client(_ provider: LLMProviderKind, replies: [ResponseURLProtocol.Reply]) -> (CompatibleLLM, URLSession) {
        ResponseURLProtocol.reset(replies)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ResponseURLProtocol.self]
        let session = URLSession(configuration: config)
        return (CompatibleLLM(configuration: configuration(provider), apiKey: "verification-placeholder", session: session), session)
    }
    private static func reply(_ provider: LLMProviderKind, text: Any? = nil, stop: String? = nil, thinking: Bool = false,
                              tools: Bool = false, refusal: Bool = false, tokens: Int = 100) throws -> ResponseURLProtocol.Reply {
        let root: [String: Any]
        if provider == .openAICompatible {
            var message: [String: Any] = ["role": "assistant", "content": text ?? NSNull()]
            if thinking { message["reasoning_content"] = "synthetic-private-thinking" }
            if tools { message["tool_calls"] = [["id": "synthetic-tool"]] }
            if refusal { message["refusal"] = "synthetic-private-refusal" }
            root = ["choices": [["message": message, "finish_reason": stop ?? "stop"]], "usage": ["completion_tokens": tokens]]
        } else {
            var blocks: [[String: Any]] = []
            if thinking { blocks.append(["type": "thinking", "thinking": "synthetic-private-thinking"]) }
            if let text = text as? String { blocks.append(["type": "text", "text": text]) }
            else if let text = text as? [[String: Any]] { blocks += text }
            if tools { blocks.append(["type": "tool_use", "id": "synthetic-tool", "name": "unavailable-tool", "input": [:]]) }
            root = ["type": "message", "content": blocks, "stop_reason": refusal ? "refusal" : stop ?? "end_turn", "usage": ["output_tokens": tokens]]
        }
        return .init(data: try JSONSerialization.data(withJSONObject: root), status: 200)
    }
    private static func budgets() throws -> [Int] {
        try ResponseURLProtocol.requests().map { try JSONSerialization.jsonObject(with: $0.data) as! [String: Any] }.compactMap { $0["max_tokens"] as? Int }
    }
    private static func generate(_ responder: CompatibleLLM, source: CaptureRecord = Self.source(), previous: [DailySummary] = []) async throws -> DailySummaryGeneration {
        try await DailySummaryGenerator().generate(day: source.createdAt, from: [source], previousSummaries: previous, responder: responder)
    }
    private static func expectFailure(_ reason: LLMResponseFailure.Reason, _ operation: () async throws -> Void) async throws -> LLMResponseFailure {
        do { try await operation(); throw Failure(message: "不完整或错误响应被接受：\(reason)") }
        catch let error as LLMResponseFailure { try expect(error.reason == reason, "响应错误分类不准确：\(error.reason) / \(reason)"); return error }
    }
    static func run() async throws {
        try await dailyProtocolAndBudget()
        try await thinkingLimitRecovery()
        try await truncatedTextNeverCommits()
        try await textBlockCompatibility()
        try await failureClassification()
        try await structuredRepairAndFallback()
        try await retryScopeGuards()
        try await chatBudgetUnchanged()
        try await diagnosticPrivacy()
        try await invalidRegenerationPreservesReport()
        try await feedbackAuditCompletion()
        print("PASS: 11 model-response scenarios (HTTP protocols, truncation, safe retries, privacy and existing reports)")
    }
    private static func dailyProtocolAndBudget() async throws {
        for provider in [LLMProviderKind.openAICompatible, .anthropicCompatible] {
            let (responder, session) = try client(provider, replies: [reply(provider, text: valid)])
            defer { session.invalidateAndCancel() }
            let result = try await generate(responder)
            try expect(result.generationKind == .cloud && result.items.contains { $0.title == "Atlas 导出验证完成" }, "每日回顾没有保存完整结构化结果")
            let used = try budgets()
            try expect(used == [6_000], "每日回顾仍沿用聊天默认 1000 tokens，或重复请求")
            let request = ResponseURLProtocol.requests()[0]
            let body = try JSONSerialization.jsonObject(with: request.data) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let system = body["system"] as? String ?? messages.first?["content"] as? String ?? ""
            try expect(system.contains("指定日期的每日回顾") && system.contains("来源 [1]")
                && !system.contains("每个事实性结论后以 [数字]"), "每日回顾混入聊天引用协议或丢失来源编号")
            try expect(request.timeout >= 180 && result.modelIssue == nil, "长回顾没有独立等待时间，或成功仍标记失败")
        }
    }
    private static func thinkingLimitRecovery() async throws {
        for provider in [LLMProviderKind.openAICompatible, .anthropicCompatible] {
            let stopped = provider == .openAICompatible ? "length" : "max_tokens"
            let (responder, session) = try client(provider, replies: [reply(provider, stop: stopped, thinking: true, tokens: 6_000), reply(provider, text: valid)])
            defer { session.invalidateAndCancel() }
            let result = try await generate(responder)
            let used = try budgets()
            try expect(used == [6_000, 8_000], "thinking-only 截断未在更大额度下受控重试一次")
            try expect(result.generationKind == .cloud && !result.content.contains("private-thinking"), "推理内容被当成回顾或重试成功后仍标记失败")
            let retryBody = String(decoding: ResponseURLProtocol.requests()[1].data, as: UTF8.self)
            try expect(!retryBody.contains("private-thinking"), "把推理文本拼进了重试请求")
        }
    }
    private static func truncatedTextNeverCommits() async throws {
        let record = source()
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try FileMemoryStore(storage: storage)
        try await store.addCapture(record)
        let saved = DailySummary(day: record.createdAt, content: "原回顾完整保留", sourceCaptureIDs: [record.id], todos: [], generationKind: .localFallback)
        try await store.upsertDailySummary(saved)
        let partial = #"{"headline":"不完整内容","progress":[{"title":"synthetic-private-answer""#
        for provider in [LLMProviderKind.openAICompatible, .anthropicCompatible] {
            let stopped = provider == .openAICompatible ? "length" : "max_tokens"
            let (responder, session) = try client(provider, replies: [reply(provider, text: partial, stop: stopped), reply(provider, text: partial, stop: stopped)])
            defer { session.invalidateAndCancel() }
            let error = try await expectFailure(.truncated) {
                let result = try await generate(responder, source: record, previous: [saved])
                let replacement = DailySummary(day: record.createdAt, content: result.content, sourceCaptureIDs: result.sourceCaptureIDs,
                    todos: result.todos, generationKind: result.generationKind, items: result.items)
                try await store.commitDailySummary(replacement, consolidation: result.consolidation)
            }
            let used = try budgets()
            try expect(used == [6_000, 8_000], "截断失败请求没有封顶")
            let state = await store.snapshot()
            try expect(state.dailySummaries.first?.content == saved.content && error.outputLimit == 8_000, "截断文本覆盖了原回顾，或错误额度不准确")
            try expect(!(error.errorDescription ?? "").contains("private-answer"), "错误信息泄露了模型正文")
        }
    }
    private static func textBlockCompatibility() async throws {
        for provider in [LLMProviderKind.openAICompatible, .anthropicCompatible] {
            let blocks: [[String: Any]] = [["type": "text", "text": "第一段"], ["type": "thinking", "thinking": "synthetic-private-thinking"], ["type": "output_text", "text": "第二段"]]
            let (responder, session) = try client(provider, replies: [reply(provider, text: blocks)])
            defer { session.invalidateAndCancel() }
            let result = try await responder.answer(to: LLMRequest(question: "测试", context: []))
            try expect(result.content == "第一段\n第二段", "兼容内容块没有按顺序提取正文，或误取推理信息")
        }
    }
    private static func failureClassification() async throws {
        for provider in [LLMProviderKind.openAICompatible, .anthropicCompatible] {
            let cases: [(ResponseURLProtocol.Reply, LLMResponseFailure.Reason)] = try [
                (reply(provider), .empty),
                (reply(provider, text: "不能作为结果", refusal: true), .refusal),
                (reply(provider, text: "调用工具", tools: true), .toolRequest),
                (reply(provider, stop: "model_context_window_exceeded"), .contextLimit),
                (.init(data: Data(#"{"error":{"type":"authentication_error","message":"synthetic-secret-body"}}"#.utf8), status: 401), .authentication),
                (.init(data: Data(#"{"error":{"code":"insufficient_quota","message":"synthetic-secret-body"}}"#.utf8), status: 429), .rateLimited),
                (.init(data: Data("<html>synthetic-secret-body</html>".utf8), status: 200), .invalidFormat),
                (.init(data: Data("<html>synthetic-secret-body</html>".utf8), status: 502), .service),
                (.init(data: Data(#"{"base_resp":{"status_code":12345,"status_msg":"synthetic-secret-body"}}"#.utf8), status: 200), .service)
            ]
            for (response, reason) in cases {
                let (responder, session) = client(provider, replies: [response])
                defer { session.invalidateAndCancel() }
                let error = try await expectFailure(reason) { _ = try await generate(responder) }
                try expect(ResponseURLProtocol.requests().count == 1, "认证、拒绝、限流或格式不匹配被盲目重试")
                try expect(!(error.errorDescription ?? "").contains("synthetic-secret") && !error.diagnosticMetadata.values.contains { $0.contains("synthetic-secret") },
                    "服务错误正文进入了界面或日志")
            }
        }
    }
    private static func structuredRepairAndFallback() async throws {
        let provider = LLMProviderKind.anthropicCompatible
        let broken = "synthetic-private-malformed {\"progress\":["
        let (responder, session) = try client(provider, replies: [reply(provider, text: broken), reply(provider, text: valid)])
        defer { session.invalidateAndCancel() }
        let repaired = try await generate(responder)
        try expect(repaired.generationKind == .cloud && ResponseURLProtocol.requests().count == 2, "结构错误未进行一次完整重试")
        try expect(!String(decoding: ResponseURLProtocol.requests()[1].data, as: UTF8.self).contains("synthetic-private-malformed"), "结构修复把无效内容当作新证据")
        let (fallbackClient, fallbackSession) = try client(provider, replies: [reply(provider, text: broken), reply(provider, text: broken)])
        defer { fallbackSession.invalidateAndCancel() }
        let local = try await generate(fallbackClient)
        try expect(local.generationKind == .localFallback && local.modelIssue?.reason == .structuredFormat && !local.items.isEmpty
            && !local.content.contains("synthetic-private-malformed"), "无效 JSON 被解析成回顾事实，或没有受控本地回退")
    }
    private actor Gate {
        let store: FileMemoryStore
        let expected: RecallState
        let action: Int
        var count = 0
        init(store: FileMemoryStore, expected: RecallState, action: Int) { self.store = store; self.expected = expected; self.action = action }
        func check(_ ids: Set<UUID>) async throws {
            count += 1
            if count == 2 {
                switch action {
                case 0: _ = try await store.deleteCapture(id: ids.first!)
                case 1: var privacy = expected.privacy; privacy.cloudUseEnabled = false; try await store.updatePrivacy(privacy)
                case 2: var config = expected.llmConfiguration; config.model = "changed-model"; try await store.updateLLMConfiguration(config)
                default: throw CancellationError()
                }
            }
            try await store.validateDailySummaryModelCall(sourceIDs: ids, expected: expected)
        }
    }
    private static func retryScopeGuards() async throws {
        for action in 0..<4 {
            let record = source()
            let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            defer { try? FileManager.default.removeItem(at: storage.rootURL) }
            let store = try FileMemoryStore(storage: storage)
            try await store.addCapture(record); try await store.updatePrivacy(PrivacySettings(cloudUseEnabled: true))
            try await store.updateLLMConfiguration(configuration(.anthropicCompatible))
            let expected = await store.snapshot().correctedForAnalysis()
            let gate = Gate(store: store, expected: expected, action: action)
            let (responder, session) = try client(.anthropicCompatible, replies: [reply(.anthropicCompatible, stop: "max_tokens", thinking: true), reply(.anthropicCompatible, text: valid)])
            defer { session.invalidateAndCancel() }
            do {
                _ = try await DailySummaryGenerator().generate(day: record.createdAt, from: [record], responder: responder,
                    beforeModelCall: { ids in try await gate.check(ids) })
                throw Failure(message: "来源/权限/模型变化或取消后仍继续了重试")
            } catch is CancellationError { try expect(action == 3, "非取消操作误报为取消") }
            catch let error as WeeklyReviewError { try expect(error == .changedSources && action != 3, "重试来源检查错误分类不准确") }
            try expect(ResponseURLProtocol.requests().count == 1, "设置变化后发出了第二次模型请求")
        }
    }
    private static func chatBudgetUnchanged() async throws {
        let (responder, session) = try client(.openAICompatible, replies: [reply(.openAICompatible, text: "正常聊天回答")])
        defer { session.invalidateAndCancel() }
        let answer = try await responder.answer(to: LLMRequest(question: "测试", context: []))
        let used = try budgets()
        try expect(answer.content == "正常聊天回答" && used == [1_000], "每日回顾额度意外改动了聊天设置")
    }
    private static func diagnosticPrivacy() async throws {
        let (responder, session) = try client(.anthropicCompatible, replies: [reply(.anthropicCompatible, stop: "synthetic-private-stop", thinking: true)])
        defer { session.invalidateAndCancel() }
        let error = try await expectFailure(.reasoningOnly) { _ = try await responder.answer(to: LLMRequest(question: "测试", context: [])) }
        let encoded = String(decoding: try JSONEncoder().encode(error.diagnosticMetadata), as: UTF8.self)
        try expect(error.diagnosticMetadata["modelStop"] == "unknown" && !encoded.contains("private-stop") && !encoded.contains("private-thinking"),
            "任意服务端字段或推理内容泄漏进安全诊断")
    }
    private static func feedbackAuditCompletion() async throws {
        let record = source()
        let (responder, session) = try client(.anthropicCompatible, replies: [reply(.anthropicCompatible, text: valid),
            reply(.anthropicCompatible, stop: "max_tokens", thinking: true, tokens: 4_000), reply(.anthropicCompatible, text: "{\"accepted\":true}")])
        defer { session.invalidateAndCancel() }
        let result = try await DailySummaryGenerator().generate(day: record.createdAt, from: [record],
            feedbackInstructions: "保留真实验证状态，不推断已经上线。", responder: responder)
        let used = try budgets()
        try expect(result.generationKind == .cloud && used == [6_000, 4_000, 8_000],
            "反馈复核仍使用 400 tokens，或推理截断未受控恢复")
        let (rejected, rejectedSession) = try client(.anthropicCompatible, replies: [reply(.anthropicCompatible, text: valid), reply(.anthropicCompatible, text: "{\"accepted\":false}")])
        defer { rejectedSession.invalidateAndCancel() }
        do {
            _ = try await DailySummaryGenerator().generate(day: record.createdAt, from: [record],
                feedbackInstructions: "保留真实验证状态。", responder: rejected)
            throw Failure(message: "复核拒绝的内容被保存")
        } catch let error as SummaryFeedbackError { if case .rejected = error { } else { throw error } }
        try expect(ResponseURLProtocol.requests().count == 2, "复核不通过时盲目重试直到模型同意")
    }
    private static func invalidRegenerationPreservesReport() async throws {
        let record = source()
        let report = DailySummary(day: record.createdAt, content: "保留已有回顾", sourceCaptureIDs: [record.id], todos: [], generationKind: .cloud)
        let (responder, session) = try client(.openAICompatible, replies: [reply(.openAICompatible, text: "{\"progress\":["), reply(.openAICompatible, text: "{\"progress\":[")])
        defer { session.invalidateAndCancel() }
        _ = try await expectFailure(.structuredFormat) { _ = try await generate(responder, source: record, previous: [report]) }
        try expect(ResponseURLProtocol.requests().count == 2, "无效重新生成没有封顶，或未经修复就失败")
    }
}

private final class ResponseURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { let data: Data; let status: Int }
    struct Observed: Sendable { let data: Data; let timeout: TimeInterval }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var observed: [Observed] = []
    static func reset(_ plan: [Reply]) { lock.lock(); defer { lock.unlock() }; replies = plan; observed = [] }
    static func requests() -> [Observed] { lock.lock(); defer { lock.unlock() }; return observed }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.lock()
        Self.observed.append(Observed(data: data, timeout: request.timeoutInterval))
        let next = Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        Self.lock.unlock()
        guard let next else { client?.urlProtocol(self, didFailWithError: FailureWithoutReply()); return }
        let http = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    private struct FailureWithoutReply: Error { }
}
