import Foundation
import RecallKit

@main
struct RecallVerifier {
    static func main() async {
        do {
            try verifyDefaultEventTemplates()
            try await verifyEventRuleMigration()
            try verifyPrivacy()
            try verifySearch()
            try verifyReminders()
            try await verifyReminderSchedulePersistence()
            try await verifyNotificationHostGuard()
            try await verifyCapturePipeline()
            try verifyConversationContextCompression()
            try await verifyPersistence()
            try await verifyCustomModelConfigurationPersistence()
            try await verifyMiniMaxAuthenticationHeaders()
            try await verifyTodayQuestionUsesTimeline()
            try await verifyLocalAnswer()
            if CommandLine.arguments.contains("--live-anthropic") {
                try await verifyLiveAnthropicCompatibility()
                print("PASS: RecallVerifier completed 15 checks, including live Anthropic compatibility.")
            } else {
                print("PASS: RecallVerifier completed 14 integration checks.")
            }
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func verifyDefaultEventTemplates() throws {
        let rules = EventRule.defaults()
        try expect(rules.count == 9, "应提供 9 个事件模板")
        try expect(Set(rules.map(\.template)) == Set(CaptureEventTemplate.allCases), "事件模板集合不完整")
        try expect(rules.contains(where: { $0.template == .manualMoment && $0.isEnabled }), "手动记录此刻应默认启用")
        try expect(rules.contains(where: { $0.template == .enterKeyTrigger && !$0.isEnabled }), "Enter 键触发记录必须默认关闭")
    }

    private static func verifyEventRuleMigration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let legacyRules = EventRule.defaults().filter { $0.template != .enterKeyTrigger }
        let legacyState = RecallState(rules: legacyRules)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacyState).write(to: storage.stateURL, options: .atomic)

        let store = try FileMemoryStore(storage: storage)
        let migratedState = await store.snapshot()
        try expect(migratedState.rules.contains(where: { $0.template == .enterKeyTrigger && !$0.isEnabled }), "旧状态没有补入默认关闭的 Enter 键规则")
    }

    private static func verifyPrivacy() throws {
        let engine = PrivacyEngine()
        let text = "alice@example.com，卡号 4111 1111 1111 1111，密码: super-secret"
        let redacted = engine.redact(text)
        try expect(!redacted.contains("alice@example.com"), "邮箱未被脱敏")
        try expect(!redacted.contains("4111 1111 1111 1111"), "卡号未被脱敏")
        try expect(!redacted.contains("super-secret"), "密码未被脱敏")
        let decision = engine.decision(for: "com.example.private", settings: PrivacySettings(excludedBundleIdentifiers: ["com.example.private"]))
        try expect(!decision.mayCapture, "排除应用仍被允许采集")
    }

    private static func verifySearch() throws {
        let matching = makeCapture(text: "和产品团队讨论 Recall 的 OCR 质量与会议摘要", app: "Notes")
        let unrelated = makeCapture(text: "今天午餐吃面", app: "Messages")
        let results = MemorySearchEngine().search(MemorySearchQuery(text: "OCR 会议摘要"), in: [unrelated, matching])
        try expect(results.first?.capture.id == matching.id, "搜索没有优先返回相关记录")
        try expect(results.first?.matchedTerms.contains("ocr") == true, "搜索未报告匹配关键词")
    }

    private static func verifyReminders() throws {
        let capture = makeCapture(text: "待办：明天回复客户关于报价的邮件", app: "Mail")
        let extractor = ReminderExtractor()
        let candidates = extractor.candidates(from: [capture], existing: [])
        try expect(candidates.count == 1, "应从待办文本创建一个提醒候选")
        try expect(candidates.first?.dueAt != nil, "未推断出明天的提醒时间")
        try expect(extractor.candidates(from: [capture], existing: candidates).isEmpty, "提醒候选去重失败")
    }

    private static func verifyReminderSchedulePersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let candidate = ReminderCandidate(title: "在用户指定时间提醒", detail: "验证自定义提醒时间。", confidence: 0.8)
        try await store.replaceReminders([candidate])

        let selectedDate = Date(timeIntervalSince1970: 1_800_000_000)
        var scheduled = candidate
        scheduled.dueAt = selectedDate
        scheduled.status = .scheduled
        try await store.updateReminder(scheduled)

        let reloaded = try FileMemoryStore(storage: storage)
        let restored = await reloaded.snapshot().reminders.first
        try expect(restored?.status.rawValue == ReminderStatus.scheduled.rawValue, "用户确认的提醒状态没有保存")
        try expect(abs((restored?.dueAt?.timeIntervalSince1970 ?? 0) - selectedDate.timeIntervalSince1970) < 0.01, "用户选择的提醒时间没有保存")
    }

    @MainActor
    private static func verifyNotificationHostGuard() async throws {
        do {
            _ = try await LocalNotificationScheduler().requestAuthorization()
            throw VerificationError.failed("命令行验证器不应直接触发系统通知授权")
        } catch ReminderNotificationError.hostApplicationRequired {
            // Expected: a raw SwiftPM executable is not a notification-capable .app host.
        }
    }

    @MainActor
    private static func verifyCapturePipeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let pipeline = CapturePipeline(
            store: store,
            storage: storage,
            screenCapturer: MockCapturer(),
            recognizer: MockRecognizer()
        )
        let rule = EventRule(template: .manualMoment, isEnabled: true, scope: .selectedWindow)
        let capture = try await pipeline.record(using: rule)
        let snapshot = await store.snapshot()

        try expect(snapshot.captures.count == 1, "记录管线没有写入本地记忆")
        try expect(capture.isRedacted, "记录管线未对 OCR 内容执行脱敏")
        try expect(capture.imageRelativePath != nil, "记录管线未保存用户允许保留的截图")
        do {
            _ = try await pipeline.record(using: rule)
            throw VerificationError.failed("记录管线未阻止短时间内的重复内容")
        } catch CapturePipelineError.duplicateCapture {
            // Expected.
        }
    }

    private static func verifyConversationContextCompression() throws {
        let history = (0..<12).flatMap { index in
            [
                ConversationMessage(role: .user, content: "第 \(index) 轮用户问题：请记录这条内容。"),
                ConversationMessage(role: .assistant, content: "第 \(index) 轮 Recall 回答：已根据本地来源整理。")
            ]
        }
        let manager = ConversationContextManager(maxRecentMessages: 8, maxSummaryCharacters: 1_000)
        let plan = manager.plan(history: history, existingSummary: nil, coveredMessageCount: 0, retrievedEvidence: [])
        try expect(plan.coveredMessageCount == 16, "长对话应将早期 16 条消息纳入摘要")
        try expect(plan.recentMessages.count == 8, "长对话应仅保留最近 8 条消息")
        try expect(plan.rollingSummary?.contains("第 0 轮用户问题") == true, "摘要未保留早期会话信息")
        let secondPlan = manager.plan(
            history: history,
            existingSummary: plan.rollingSummary,
            coveredMessageCount: plan.coveredMessageCount,
            retrievedEvidence: []
        )
        try expect(secondPlan.rollingSummary == plan.rollingSummary, "没有新历史时不应重复压缩相同消息")
    }

    private static func verifyPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let capture = makeCapture(text: "本地持久化验证", app: "Recall")
        try await store.addCapture(capture)
        let reloaded = try FileMemoryStore(storage: storage)
        let snapshot = await reloaded.snapshot()
        try expect(snapshot.captures.count == 1, "重新加载后记录丢失")
        try expect(snapshot.captures.first?.ocrText == "本地持久化验证", "重新加载后的 OCR 文本不一致")
    }

    private static func verifyCustomModelConfigurationPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let custom = LLMConfiguration(
            provider: .anthropicCompatible,
            baseURLString: "https://example.invalid/custom-anthropic",
            model: "my-custom-model",
            apiKey: "plain-text-test-key"
        )
        try await store.updateLLMConfiguration(custom)
        let reloaded = try FileMemoryStore(storage: storage)
        let restored = await reloaded.snapshot().llmConfiguration
        try expect(restored.provider == .anthropicCompatible, "自定义模型类型没有保存")
        try expect(restored.baseURLString == custom.baseURLString, "自定义 API 地址没有保存")
        try expect(restored.model == custom.model, "自定义模型名称没有保存")
        try expect(restored.apiKey == "plain-text-test-key", "普通文本 API Key 没有保存")
    }

    private static func verifyMiniMaxAuthenticationHeaders() async throws {
        HeaderInspectingURLProtocol.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [HeaderInspectingURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let configuration = LLMConfiguration(
            provider: .anthropicCompatible,
            baseURLString: "https://api.minimaxi.com/anthropic",
            model: "MiniMax-M3"
        )
        let evidence = makeCapture(text: "MiniMax 认证头离线验证", app: "Verifier")
        let response = try await CompatibleLLM(configuration: configuration, apiKey: "test-key", session: session).answer(
            to: LLMRequest(question: "仅回复连接成功", context: [evidence])
        )
        let headers = HeaderInspectingURLProtocol.headers()
        try expect(response.content == "连接成功", "MiniMax 认证头验证未收到模拟响应")
        try expect(headers["X-Api-Key"] == "test-key", "MiniMax 请求缺少 X-Api-Key")
        try expect(headers["Authorization"] == "Bearer test-key", "MiniMax 请求缺少 Bearer 认证回退")
        try expect(headers["anthropic-version"] == "2023-06-01", "MiniMax 请求缺少 Anthropic 版本头")
    }

    private static func verifyLiveAnthropicCompatibility() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["RECALL_LIVE_API_KEY"], !apiKey.isEmpty else {
            throw VerificationError.failed("实时 Anthropic 验证需要 RECALL_LIVE_API_KEY 环境变量。")
        }
        let configuration = LLMConfiguration(
            provider: .anthropicCompatible,
            baseURLString: "https://api.minimaxi.com/anthropic",
            model: "MiniMax-M3.0",
            maxOutputTokens: 96
        )
        let evidence = makeCapture(text: "Recall 的测试记忆只允许回答 LIVE_MODEL_OK。", app: "Verifier")
        let answer = try await CompatibleLLM(configuration: configuration, apiKey: apiKey).answer(
            to: LLMRequest(question: "只回答 LIVE_MODEL_OK", context: [evidence])
        )
        let normalizedAnswer = answer.content.replacingOccurrences(of: " ", with: "")
        try expect(!normalizedAnswer.isEmpty, "实时模型没有返回可解析文本")
        try expect(!normalizedAnswer.contains("记忆证据为空") && !normalizedAnswer.contains("没有可用记忆"), "实时模型忽略了已提供的记忆证据")
        try expect(answer.citedCaptureIDs == [evidence.id], "实时模型回答没有保留本地记忆引用")
    }

    @MainActor
    private static func verifyTodayQuestionUsesTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let capture = makeCapture(text: "上午完成了 Recall 的时间线检索修复。", app: "Xcode")
        try await store.addCapture(capture)
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .localOnly))

        let answer = try await MemoryAssistant(store: store).ask("今天做了什么？")
        try expect(answer.citations == [capture.id], "今天的问题没有引用当天的时间线记录")
        try expect(answer.content.contains("时间线检索修复"), "今天的问题没有返回当天的记录内容")
    }

    private static func verifyLocalAnswer() async throws {
        let capture = makeCapture(text: "会议结论：周五提交设计方案", app: "Notes")
        let answer = try await ExtractiveMemoryResponder().answer(to: LLMRequest(question: "什么时候提交？", context: [capture]))
        try expect(answer.citedCaptureIDs == [capture.id], "本地回答缺少来源引用")
        try expect(answer.content.contains("周五提交设计方案"), "本地回答未包含检索记录")
    }

    private static func makeCapture(text: String, app: String) -> CaptureRecord {
        CaptureRecord(
            eventTemplate: .manualMoment,
            sourceAppName: app,
            sourceBundleIdentifier: "com.example.\(app.lowercased())",
            windowTitle: "验证窗口",
            contentHash: UUID().uuidString,
            ocrText: text,
            summary: text,
            tags: []
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationError.failed(message) }
    }
}

private final class HeaderInspectingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let requestLock = NSLock()
    nonisolated(unsafe) private static var capturedHeaders: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestLock.lock()
        Self.capturedHeaders = request.allHTTPHeaderFields ?? [:]
        Self.requestLock.unlock()

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let body = Data("{\"content\":[{\"type\":\"text\",\"text\":\"连接成功\"}]}".utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        requestLock.lock()
        capturedHeaders = [:]
        requestLock.unlock()
    }

    static func headers() -> [String: String] {
        requestLock.lock()
        defer { requestLock.unlock() }
        return capturedHeaders
    }
}

@MainActor
private final class MockCapturer: ScreenCapturing {
    func capture(scope: CaptureScope) async throws -> CapturePayload {
        CapturePayload(
            imageData: Data("fake-png-binary".utf8),
            sourceAppName: "Mock Editor",
            sourceBundleIdentifier: "com.example.mockeditor",
            windowTitle: "设计文档"
        )
    }

    func requestScreenRecordingAccess() -> Bool { true }
}

private struct MockRecognizer: TextRecognizing {
    func recognizeText(in imageData: Data) async throws -> String {
        "请联系 alice@example.com，密码: demo-secret"
    }
}

enum VerificationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}
