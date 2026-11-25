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
        print("PASS: 1 ask performance scenario (capture revision)")
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
