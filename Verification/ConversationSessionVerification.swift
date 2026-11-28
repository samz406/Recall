import Foundation
import RecallKit

/// 每个主题与多会话线程管理：作用域隔离、新建归档、历史切换、单条删除、原地重答与迟到写入丢弃。
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

        // 多会话线程管理：新建对话保留旧线程、可切回、可原地准备重新回答、可删除单条历史会话。
        try await store.addMessage(ConversationMessage(role: .assistant, content: "全局第一轮回答"))
        let sessionsBeforeNew = await store.conversationSessions()
        try expect(sessionsBeforeNew.count == 1 && sessionsBeforeNew[0].title == "全局问题", "首条消息没有生成会话摘要标题")
        let firstThreadID = sessionsBeforeNew[0].id

        _ = try await store.startNewConversation(topicID: nil)
        let freshMessages = await store.snapshot().messages
        let afterNewSessions = await store.conversationSessions()
        try expect(freshMessages.isEmpty, "新建对话后当前消息未清空")
        try expect(afterNewSessions.contains { $0.id == firstThreadID }, "新建对话丢失了此前的历史对话")

        try await store.addMessage(ConversationMessage(role: .user, content: "第二个独立话题"))
        let badReply = ConversationMessage(role: .assistant, content: "不满意的旧回答")
        try await store.addMessage(badReply)
        let twoSessions = await store.conversationSessions()
        try expect(twoSessions.count == 2, "新增对话线程未进入历史列表")

        let regenQuestion = try await store.prepareRegeneration(removingAssistantMessageID: badReply.id)
        let messagesAfterPrepare = await store.snapshot().messages
        try expect(regenQuestion == "第二个独立话题" && !messagesAfterPrepare.contains { $0.id == badReply.id },
                   "重新回答前未移除旧失败轮次")
        try await store.addMessage(ConversationMessage(role: .user, content: regenQuestion ?? ""))
        try await store.addMessage(ConversationMessage(role: .assistant, content: "重新生成后的回答"))

        let selectedTopic = try await store.selectConversation(id: firstThreadID)
        let switchedBackMessages = await store.snapshot().messages
        try expect(selectedTopic == nil && switchedBackMessages.contains { $0.content == "全局第一轮回答" },
                   "切回历史对话未恢复第一条会话内容")

        let reopened = try verificationStore(storage: storage)
        let reopenedSessions = await reopened.conversationSessions()
        try expect(reopenedSessions.count == 2, "重新打开存档后丢失了多会话历史")
        try await reopened.deleteConversation(id: firstThreadID)
        let remaining = await reopened.conversationSessions()
        try expect(remaining.count == 1 && remaining[0].title == "第二个独立话题", "删除当前历史对话后未切回剩余会话")

        print("PASS: conversation sessions stay isolated per scope, support multi-thread history/regeneration/deletion, and drop stale writes")
    }
}
