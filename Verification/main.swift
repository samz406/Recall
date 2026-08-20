import Foundation
import RecallKit

@main
struct RecallVerifier {
    static func main() async {
        do {
            try verifyDefaultEventTemplates()
            try verifyPrivacy()
            try verifySearch()
            try verifyReminders()
            try await verifyCapturePipeline()
            try await verifyPersistence()
            try await verifyLocalAnswer()
            print("PASS: RecallVerifier completed 7 integration checks.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func verifyDefaultEventTemplates() throws {
        let rules = EventRule.defaults()
        try expect(rules.count == 8, "应提供 8 个事件模板")
        try expect(Set(rules.map(\.template)) == Set(CaptureEventTemplate.allCases), "事件模板集合不完整")
        try expect(rules.contains(where: { $0.template == .manualMoment && $0.isEnabled }), "手动记录此刻应默认启用")
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
