import Foundation
import RecallKit

/// Synthetic regression for the controls introduced by the page redesign.
@MainActor
enum PageExperienceVerification {
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw ModelReviewVerification.Failure(message: message) }
    }
    static func run() async throws {
        try settingsMigration()
        try await referenceSwitches()
        try rangeRestrictions()
        try topicRestrictions()
        try await scopedConversation()
        try await feedbackAndClear()
        try await deletionUndo()
        print("PASS: 7 page-experience scenarios (legacy settings, reference switches, date/topic isolation, scoped chat, feedback/clear and deletion undo)")
    }
    private static func source(_ text: String, date: Date = .now) -> CaptureRecord {
        CaptureRecord(eventTemplate: .manualMoment, createdAt: date, sourceAppName: "合成验证", sourceBundleIdentifier: "example.page-verification",
            contentHash: UUID().uuidString, ocrText: text, textOrigin: .userInput)
    }
    private static func settingsMigration() throws {
        let data = Data(#"{"automaticOrganization":true,"retainExplicitMemories":true}"#.utf8)
        let settings = try JSONDecoder().decode(MemoryKnowledgeSettings.self, from: data)
        try expect(settings.referencesEnabled && settings.disabledClaimKeys == nil, "旧档案缺少新增开关时必须可读取并保留原行为")
        let empty = source("合成普通记录")
        try expect(MemoryQueryScope.all.applying(to: RecallState(captures: [empty])).captures == [empty], "全部范围不能改变原始记录")
    }
    private static func referenceSwitches() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-page-switches-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try FileMemoryStore(storage: storage)
        _ = try await store.remember(MemoryDirective.parse("记住：以后回答先结论后细节，简洁一点")!)
        var state = await store.snapshot()
        let claim = state.memoryKnowledge.claims.first { $0.usable() && $0.kind == .preference }!
        func plan(_ state: RecallState) -> MemoryRetrievalPlan { MemoryRetrievalEngine().plan(question: "回答怎么写", state: state, fallback: state.captures) }
        try expect(plan(state).preferences?.contains("简洁") == true, "启用的明确偏好应进入对话")
        var settings = state.memoryKnowledgeSettings; settings.referenceInChat = false
        try await store.updateMemoryKnowledgeSettings(settings); state = await store.snapshot()
        try expect(plan(state).preferences == nil && plan(state).evidence.isEmpty && state.captures.count == 1, "关闭总开关应停止引用，保留原记录")
        settings.referenceInChat = true; settings.disabledClaimKeys = [claim.key]
        try await store.updateMemoryKnowledgeSettings(settings)
        let reopened = try FileMemoryStore(storage: storage); state = await reopened.snapshot()
        try expect(!state.memoryKnowledgeSettings.references(claim) && plan(state).preferences == nil && plan(state).evidence.isEmpty, "单条停用必须持久化且不能经原文回退绕过")
        settings.disabledClaimKeys = []
        try await reopened.updateMemoryKnowledgeSettings(settings); state = await reopened.snapshot()
        try expect(plan(state).preferences?.contains("简洁") == true, "重新启用后原记忆应恢复，无需创建重复记录")
    }
    private static func rangeRestrictions() throws {
        let now = Date.now, start = now.addingTimeInterval(-604_800)
        let before = source("范围外记录", date: start.addingTimeInterval(-1))
        let first = source("范围起点记录", date: start)
        let last = source("范围内记录", date: now.addingTimeInterval(-1))
        let end = source("范围终点不含", date: now)
        var state = RecallState(captures: [before, first, last, end])
        state.dailySummaries = [DailySummary(day: start, content: "含越界来源的派生结果", sourceCaptureIDs: [before.id, first.id], todos: [], generationKind: .cloud)]
        state.messages = [ConversationMessage(role: .assistant, content: "旧会话范围外结论")]
        state.conversationSummary = "旧范围外压缩"
        let scoped = MemoryQueryScope(start: start, end: now).applying(to: state)
        try expect(Set(scoped.captures.map(\.id)) == [first.id, last.id] && scoped.dailySummaries.isEmpty && scoped.messages.isEmpty && scoped.conversationSummary == nil,
            "日期范围必须为起点包含、终点不含，并移除越界派生结果和旧对话上下文")
    }
    private static func topicRestrictions() throws {
        let a = try ManualMatterNote(title: "Atlas 项目分页验证", detail: "合成分页验证已完成。", status: .completed, eventAt: .now).capture(recordedAt: .now)
        let b = try ManualMatterNote(title: "Nova 项目图表验证", detail: "合成图表验证已完成。", status: .completed, eventAt: .now).capture(recordedAt: .now)
        var state = RecallState(captures: [a, b])
        state.memoryKnowledge = MemoryKnowledgeEngine().reconcile(state, force: true)
        guard let topic = state.memoryKnowledge.claims.first(where: { $0.sourceIDs == [a.id] })?.subjectID else { throw ModelReviewVerification.Failure(message: "合成主题未建立") }
        try expect(MemoryQueryScope(topicID: topic).applying(to: state).captures.map(\.id) == [a.id], "主题限制不能包含其他主题")
        try expect(MemoryQueryScope(topicID: "missing").applying(to: state).captures.isEmpty, "未知主题应为空，不能回退到全部记忆")
    }
    private static func scopedConversation() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-page-scope-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let now = Date.now
        var state = RecallState(captures: [source("[聊天·自己] Atlas 范围内分页验证已完成。", date: now.addingTimeInterval(-60)), source("[聊天·自己] Nova 范围外发布已完成。", date: now.addingTimeInterval(-900_000))])
        state.llmConfiguration.provider = .localOnly
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: storage.stateURL)
        let store = try FileMemoryStore(storage: storage), assistant = MemoryAssistant(store: store)
        var evidenceCount: Int?
        let answer = try await assistant.ask("我最近做了什么", scope: MemoryQueryScope(start: now.addingTimeInterval(-604_800), end: now), onEvidenceReady: { evidenceCount = $0 })
        try expect(!answer.citations.contains(state.captures[1].id) && evidenceCount != nil, "范围外的记录不能被聊天引用，进度必须来自实际检索结果")
        let after = await store.snapshot()
        try expect(after.captures.count == 2, "筛选范围不能删改底层档案")
    }
    private static func feedbackAndClear() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-page-feedback-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try FileMemoryStore(storage: storage)
        let user = ConversationMessage(role: .user, content: "合成问题"), answer = ConversationMessage(role: .assistant, content: "合成回答")
        try await store.addMessage(user); try await store.addMessage(answer)
        try await store.rateMessage(id: answer.id, helpful: false)
        let reopened = try FileMemoryStore(storage: storage), rated = await reopened.snapshot()
        try expect(rated.messages.last?.helpful == false, "回答反馈必须保存到档案")
        try await reopened.rateMessage(id: answer.id, helpful: nil)
        _ = try await reopened.clearConversation()
        let cleared = await reopened.snapshot()
        try expect(cleared.messages.count == 1 && cleared.messages[0].role == .system && cleared.conversationSummary == nil, "新对话必须清除当前会话及压缩上下文")
    }
    private static func deletionUndo() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-page-undo-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let record = source("[聊天·自己] 合成删除回退记录。")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(RecallState(captures: [record])).write(to: storage.stateURL)
        let store = try FileMemoryStore(storage: storage)
        let removed = try await store.moveCapturesToRecentlyDeleted(ids: [record.id], reason: .noLongerNeeded, suppressSimilar: false)!
        let empty = await store.snapshot()
        try expect(empty.captures.isEmpty, "删除后记录必须立即退出时间线")
        _ = try await store.restoreRecentlyDeleted(id: removed.id)
        let restored = await store.snapshot()
        try expect(restored.captures.map(\.id) == [record.id], "撤销应恢复原记录，不能生成新身份或重复条目")
    }
}
