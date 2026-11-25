import Foundation
import RecallKit

/// 问一问的性能相关约束：隐私复核只比较修订号，不逐条比对全部文本。
@MainActor
enum AskPerformanceVerification {
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }

    static func run() async throws {
        try await messagesDoNotBumpCaptureRevision()
        try await finalRequestDropsDuplicatedToolText()
        try await messagesLiveInSidecar()
        print("PASS: 3 ask performance scenarios (capture revision, duplicated tool text, message sidecar)")
    }

    /// 每条消息原本都会编码整份存档（含全部 OCR）。消息改存 sidecar 后，
    /// 主存档不再包含消息，重新打开也能读回。
    private static func messagesLiveInSidecar() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-ask-sidecar-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        do {
            let store = try verificationStore(storage: storage)
            try await store.addCapture(CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "合成验证",
                sourceBundleIdentifier: "example.ask-sidecar", contentHash: UUID().uuidString, ocrText: "ATLAS-CAPTURE-TEXT", textOrigin: .userInput))
            try await store.addMessage(ConversationMessage(role: .user, content: "SIDECAR-SYNTHETIC-1"))
        }
        let main = try String(contentsOf: storage.stateURL, encoding: .utf8)
        try expect(!main.contains("SIDECAR-SYNTHETIC-1"), "消息不应再写入主存档")
        try expect(main.contains("ATLAS-CAPTURE-TEXT"), "主存档仍应包含截图文本")
        try expect(FileManager.default.fileExists(atPath: storage.conversationURL.path), "应生成会话 sidecar 文件")

        let reopened = try verificationStore(storage: storage)
        let messages = await reopened.snapshot().messages
        try expect(messages.contains { $0.content == "SIDECAR-SYNTHETIC-1" }, "重新打开后消息应还在")
    }

    /// 逐来源原文已经随 shown 发给回答模型，最终请求不再重复携带同样的工具结果；
    /// 不提供逐来源原文的工具（如 list_days）仍要保留。
    private static func finalRequestDropsDuplicatedToolText() async throws {
        let (storage, store, capture) = try await AskAgentVerification.fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let script = ScriptedAskModel { request in
            if request.purpose == .chatPlanning {
                let tool = request.question.contains("已读取的工具结果") ? "read_records" : "list_days"
                let args: [String: Any] = tool == "read_records" ? ["ids": [capture.id.uuidString]] : ["from": "2026-01-01", "to": "2026-01-01"]
                return LLMAnswer(content: json(["calls": [["tool": tool, "args": args]]]), citedCaptureIDs: [])
            }
            return LLMAnswer(content: "按已读材料回答", citedCaptureIDs: [])
        }
        _ = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script, limits: AskLimits(maxRounds: 2))
        let chat = await script.recorded().first { $0.purpose == .chat }
        let supplement = chat?.supplementaryContext ?? ""
        try expect(chat != nil, "应走到最终回答请求")
        try expect(!supplement.contains("[read_records]"), "最终回答请求不应重复携带已作为逐来源原文提供的工具结果")
        try expect(supplement.contains("[list_days]"), "没有逐来源原文的工具结果仍要保留")
    }

    /// 聊天消息会让整份存档重写，但不是截图内容变化；隐私复核不该因此走慢路径。
    private static func messagesDoNotBumpCaptureRevision() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-ask-perf-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage)
        let capture = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "合成验证", sourceBundleIdentifier: "example.ask-perf",
            contentHash: UUID().uuidString, ocrText: "AtlasScopeToken 合成文本", textOrigin: .userInput)
        try await store.addCapture(capture)
        let before = await store.captureContentRevision()
        try await store.addMessage(ConversationMessage(role: .user, content: "你好"))
        let afterMessage = await store.captureContentRevision()
        try expect(before == afterMessage, "聊天消息不应改变截图内容修订号")

        let other = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "合成验证", sourceBundleIdentifier: "example.ask-perf",
            contentHash: UUID().uuidString, ocrText: "另一条合成文本", textOrigin: .userInput)
        try await store.addCapture(other)
        let afterCapture = await store.captureContentRevision()
        try expect(afterCapture != afterMessage, "新增截图必须改变截图内容修订号")
    }
}
