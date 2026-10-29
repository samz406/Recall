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
        try await recentRangeCoversDays()
        try await feedbackAndClear()
        try await deletionUndo()
        print("PASS: 8 page-experience scenarios (legacy settings, reference switches, date/topic isolation, scoped chat, seven-day coverage, feedback/clear and deletion undo)")
    }
    private struct NoCloudResponder: LLMResponding {
        func answer(to request: LLMRequest) async throws -> LLMAnswer { throw LLMError.serviceError("禁用的记忆不得发出模型请求") }
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
        var semanticState = state; semanticState.privacy.cloudUseEnabled = true
        let selected = try await MemorySemanticLookup().topics(for: "我之前的回答偏好是什么", in: semanticState, responder: NoCloudResponder())
        try expect(selected.isEmpty, "停用的长期记忆也不能作为语义查找的名称发给模型")
        settings.referenceInChat = true; settings.disabledClaimKeys = [claim.key]
        try await store.updateMemoryKnowledgeSettings(settings)
        let reopened = try FileMemoryStore(storage: storage); state = await reopened.snapshot()
        try expect(!state.memoryKnowledgeSettings.references(claim) && plan(state).preferences == nil && plan(state).evidence.isEmpty, "单条停用必须持久化且不能经原文回退绕过")
        settings.disabledClaimKeys = []
        try await reopened.updateMemoryKnowledgeSettings(settings); state = await reopened.snapshot()
        try expect(plan(state).preferences?.contains("简洁") == true, "重新启用后原记忆应恢复，无需创建重复记录")
        var experience = claim; experience.id = UUID(); experience.key += ":experience"; experience.kind = .experience
        experience.title = "Atlas 解决分页边界的方法"; experience.content = "Atlas 先复现分页边界，再验证空结果与最后一页。"
        state.memoryKnowledge.claims.append(experience)
        let reader = MemoryRetrievalEngine()
        let enabled = reader.plan(question: "Atlas 上次怎么解决分页问题", state: state, fallback: state.captures)
        state.memoryKnowledgeSettings.disabledClaimKeys = [experience.key]
        let disabled = reader.plan(question: "Atlas 上次怎么解决分页问题", state: state, fallback: state.captures)
        try expect(enabled.evidence.contains { $0.id == experience.id } && !disabled.evidence.contains { $0.id == experience.id }, "历史经验的单条开关也必须实际停止引用")
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
        state.llmConfiguration.provider = .openAICompatible
        state.privacy.cloudUseEnabled = false
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
    private static func recentRangeCoversDays() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-page-week-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let now = Date.now
        let records = try (0..<7).map { day in
            let date = day == 0 ? now : Calendar.current.date(byAdding: .day, value: -day, to: Calendar.current.startOfDay(for: now))!.addingTimeInterval(43_200)
            return try ManualMatterNote(title: "Atlas 第\(day)项分页验证", detail: "合成记录：第\(day)项分页方案已核对，等待下一阶段验收。", status: .progressed, eventAt: date).capture(recordedAt: date)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(RecallState(captures: records)).write(to: storage.stateURL)
        let store = try FileMemoryStore(storage: storage), assistant = MemoryAssistant(store: store)
        let answer = try await assistant.ask("我做了哪些事情", scope: MemoryQueryScope(recentDays: 7))
        let days = Set(records.filter { answer.citations.contains($0.id) }.map { Calendar.current.startOfDay(for: $0.createdAt) })
        try expect(days.count == 7, "从范围选择最近七天时，即使问题未复述日期也应覆盖各天，不能只回答今天")
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
