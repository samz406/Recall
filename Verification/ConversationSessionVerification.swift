import Foundation
import RecallKit

/// 每个主题一套会话：切换后互不相通，删除主题时连带删除。
enum ConversationSessionVerification {
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }

    static func run() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-session-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage)

        try await store.addMessage(ConversationMessage(role: .user, content: "全局问题"))
        try await store.activateSession(topicID: "topic:alpha")
        let afterSwitch = await store.snapshot().messages
        try expect(afterSwitch.isEmpty, "切到主题会话后不应看到全局消息")
        try await store.addMessage(ConversationMessage(role: .user, content: "主题问题"))
        try await store.activateSession(topicID: nil)
        let back = await store.snapshot().messages
        try expect(back.contains { $0.content == "全局问题" }, "切回全局会话应恢复原消息")
        try expect(!back.contains { $0.content == "主题问题" }, "主题消息不应带进全局会话")

        try await store.activateSession(topicID: "topic:alpha")
        let restored = await store.snapshot().messages
        try expect(restored.contains { $0.content == "主题问题" }, "切回主题会话应恢复原消息")

        try await store.deleteSession(topicID: "topic:alpha")
        try await store.activateSession(topicID: "topic:alpha")
        let afterDelete = await store.snapshot().messages
        try expect(afterDelete.isEmpty, "删除主题会话后不应恢复旧消息")

        // 在途回答不能写进切换后的会话：用旧会话身份写入必须被丢弃。
        let stale = await store.conversationSnapshot().id
        try await store.activateSession(topicID: nil)
        let current = await store.conversationSnapshot().id
        await store.recordAnswerCitations([UUID()], inConversation: stale, topicID: nil)
        let afterStale = await store.lastCitedSourceIDs()
        try expect(afterStale.isEmpty, "切走后的回答写回了新会话")
        await store.recordAnswerCitations([UUID()], inConversation: current, topicID: nil)
        let afterCurrent = await store.lastCitedSourceIDs()
        try expect(afterCurrent.count == 1, "当前会话的回答引用没有写回")
        print("PASS: conversation sessions stay isolated per scope, drop stale writes and are deleted with the topic")
    }
}
