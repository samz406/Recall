import Foundation
import RecallKit

@MainActor
enum MemoryExperienceVerification {
    private struct Failure: LocalizedError { var errorDescription: String? }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(errorDescription: message) } }

    static func run() async throws {
        try await conversationLifecycle()
        try await periodPreferences()
        print("PASS: memory experience: direct remember/edit/pause/resume/forget, ambiguous-command safety, source and review preservation, undo, restart and actual period prompt personalization")
    }
    private static func conversationLifecycle() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("memory-experience-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage)
        let assistant = MemoryAssistant(store: store)
        let saved = try await assistant.ask("记住：以后回答简洁一点，先给结论")
        var state = await store.snapshot()
        try expect(saved.content.hasPrefix("已记住：") && saved.citations.count == 1, "对话记住没有可撤销回执")
        guard let initial = state.memoryKnowledge.claims.first(where: { $0.usable() && $0.kind.isPersonal }) else { throw Failure(errorDescription: "未建立明确记忆") }
        let history = DailySummary(day: .now, content: "合成的已保存历史回顾。", sourceCaptureIDs: initial.sourceIDs, todos: [], generationKind: .localFallback)
        try await store.upsertDailySummary(history)
        _ = try await assistant.ask("修改记忆：以后回答简洁一点，先给结论改为以后回答详细一点，保留依据")
        state = await store.snapshot()
        try expect(state.dailySummaries.contains { $0.id == history.id }, "修改偏好删除了已有回顾")
        try expect(state.captures.contains { initial.sourceIDs.contains($0.id) }, "修改偏好删除了原始来源")
        let context = PersonalMemoryContext.text(in: state, question: "项目验证结果如何")
        try expect(context.contains("详细一点") && !context.contains("简洁一点"), "下一次使用没有替换旧偏好")
        _ = try await assistant.ask("暂停参考：以后回答详细一点，保留依据")
        state = await store.snapshot()
        try expect(PersonalMemoryContext.text(in: state, question: "项目验证结果如何").isEmpty, "暂停后仍注入偏好")
        _ = try await assistant.ask("恢复参考：以后回答详细一点，保留依据")
        state = await store.snapshot()
        try expect(PersonalMemoryContext.text(in: state, question: "项目验证结果如何").contains("详细一点"), "恢复参考未生效")
        let before = state.captures
        _ = try await assistant.ask("不再记住：以后回答详细一点，保留依据")
        state = await store.snapshot()
        try expect(state.captures == before && state.dailySummaries.contains { $0.id == history.id }, "忘记个人信息级联删除了原始记录或回顾")
        try expect(PersonalMemoryContext.text(in: state, question: "项目验证结果如何").isEmpty, "忘记后仍应用旧偏好")
        try await store.organizeMemory(force: true)
        let reopened = try verificationStore(storage: storage, deferMaintenance: true)
        state = await reopened.snapshot()
        try expect(PersonalMemoryContext.text(in: state, question: "项目验证结果如何").isEmpty, "重建或重启使已忘记内容复活")

        let another = MemoryAssistant(store: reopened)
        let first = try await another.ask("记住：以后回答使用中文")
        let second = try await another.ask("记住：以后回答语气自然一点")
        let beforeAmbiguity = await reopened.snapshot().memoryKnowledge.claims.filter { $0.usable() }.map(\.id)
        let ambiguous = try await another.ask("忘记：以后回答")
        let afterAmbiguity = await reopened.snapshot().memoryKnowledge.claims.filter { $0.usable() }.map(\.id)
        try expect(ambiguous.content.contains("多条") && beforeAmbiguity == afterAmbiguity, "模糊指令批量修改了多条记忆")
        try expect(MemoryManagementCommand.parse("请问你能忘记以前的信息吗？") == nil, "普通问题触发了记忆修改")
        try await reopened.undoRemembering(sourceID: second.citations[0])
        state = await reopened.snapshot()
        try expect(state.memoryKnowledge.claims.contains { $0.usable() && $0.sourceIDs.contains(first.citations[0]) }
            && !state.memoryKnowledge.claims.contains { $0.usable() && $0.sourceIDs.contains(second.citations[0]) }, "撤销操作影响了其他记忆")
        let backup = storage.stateURL.appendingPathExtension("memory-backup")
        try FileManager.default.moveItem(at: storage.stateURL, to: backup)
        try FileManager.default.createDirectory(at: storage.stateURL, withIntermediateDirectories: false)
        guard let live = state.memoryKnowledge.claims.first(where: { $0.usable() && $0.kind.isPersonal }) else { throw Failure(errorDescription: "缺少失败回滚夹具") }
        do { try await reopened.retireMemory(id: live.id); throw Failure(errorDescription: "写盘失败未上报") }
        catch is Failure { throw Failure(errorDescription: "写盘失败未上报") } catch {}
        try expect(await reopened.snapshot().memoryKnowledge.claims.contains { $0.id == live.id && $0.usable() }, "写盘失败丢失了原记忆")
        try FileManager.default.removeItem(at: storage.stateURL)
        try FileManager.default.moveItem(at: backup, to: storage.stateURL)
    }
    actor PeriodProbe: LLMResponding {
        let model = SummaryAccuracyVerification.PeriodModel()
        var requests: [LLMRequest] = []
        func answer(to request: LLMRequest) async throws -> LLMAnswer { requests.append(request); return try await model.answer(to: request) }
        func log() -> [LLMRequest] { requests }
    }
    private static func periodPreferences() async throws {
        let now = Date.now, date = now.addingTimeInterval(-86_400)
        let source = KnowledgeProjectionVerification.capture("Atlas 分页核对已经完成，保存了边界验证记录。", at: date, title: "合成对话")
        var review = KnowledgeProjectionVerification.review(day: Calendar.current.startOfDay(for: date), evidence: [source.id], topic: "Atlas 分页核对", quotes: [DailyLedgerQuote(text: source.ocrText, sourceIDs: [source.id], speaker: "user")])
        review.ledger[0].category = "work"
        let directive = MemoryDirective.parse("记住：以后工作周报先给结论，正文简洁一点")!
        let memory = CaptureRecord(eventTemplate: .manualMoment, sourceAppName: "合成约定", contentHash: "memory-context", ocrText: directive.content, textOrigin: .userInput, memoryDirective: directive)
        var state = RecallState(captures: [source, memory], dailySummaries: [review])
        state.privacy.cloudUseEnabled = true
        state.memoryKnowledge = MemoryKnowledgeEngine().reconcile(state, force: true)
        let model = PeriodProbe()
        _ = try await PeriodReviewFromDaily().generate(in: state, period: .make(.recentSeven), template: ReviewTemplate(kind: .work), responder: model)
        let requests = await model.log()
        try expect(requests.first?.question.contains(directive.content) == true, "工作周报没有实际读取长期写作约定")
        state.memoryKnowledgeSettings.referenceInChat = false
        try expect(PersonalMemoryContext.text(in: state, question: "工作周报").isEmpty, "关闭个人信息参考后仍注入约定")
    }
}
