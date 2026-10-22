import Foundation
import RecallKit

/// Invented records cover the date-first review flow and repairs of old topic caches.
enum ReviewFlowVerification {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    static func run() async throws {
        try await dateFirstReview()
        try await historicalReorganization()
    }
    private static func dateFirstReview() async throws {
        let now = Date.now
        func note(_ title: String, category: ReviewCategory, daysAgo: Double) throws -> CaptureRecord {
            let day = now.addingTimeInterval(-daysAgo * 86_400)
            return try ManualMatterNote(title: title, detail: "留下了可供回看的具体记录。", status: .explored,
                eventAt: day, reviewCategory: category).capture(recordedAt: day)
        }
        let work = try note("Atlas 账单核对", category: .work, daysAgo: 2)
        let life = try note("周末植物观察", category: .personal, daysAgo: 1)
        let study = try note("木刻基础练习", category: .learning, daysAgo: 3)
        let older = try note("旧月度计划回看", category: .work, daysAgo: 10)
        let state = RecallState(captures: [work, life, study, older])
        let period = ReviewPeriod.make(.recentSeven, at: now)
        let engine = WeeklyReviewEngine()
        var template = ReviewTemplate(kind: .personal)
        template.headings[ReviewSection.notes.rawValue] = "这一周的记录"
        let report = try await engine.generate(in: state, period: period, template: template, now: now)
        try expect(report.items.count == 3 && report.sourceIDs == Set([work.id, life.id, study.id]),
            "我的一周应无需预选主题，按日期包含工作、生活、学习，并排除范围外记录")
        try expect(report.markdown.contains("这一周的记录"), "输出格式设置没有用于当前日期范围的回顾")
        let studyID = engine.topics(in: state).first { $0.evidenceIDs.contains(study.id) }!.id
        let scope = ReviewScope(topicIDs: [studyID])
        let selected = try await engine.generate(in: state, period: period, template: template, scope: scope, now: now)
        try expect(selected.sourceIDs == Set([study.id]), "主动筛选后没有缩小内容范围")
        let reset = try await engine.generate(in: state, period: period, template: template,
            scope: ReviewScope(), now: now)
        try expect(reset.sourceIDs == report.sourceIDs, "关闭主题筛选后没有恢复整个日期范围")
        let workReport = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .work), now: now)
        try expect(workReport.sourceIDs == Set([work.id]), "简化选择流程后工作回顾混入了生活或学习")
    }
    private static func historicalReorganization() async throws {
        let now = Date.now
        func capture(_ text: String) -> CaptureRecord {
            CaptureRecord(eventTemplate: .manualMoment, createdAt: now.addingTimeInterval(-86_400),
                sourceAppName: "合成测试窗口", windowTitle: "无关的旧窗口标题", contentHash: UUID().uuidString,
                ocrText: "[聊天·自己] " + text, textOrigin: .screenOCR)
        }
        let incomplete = capture("已定位故障原因,正在实施修复。")
        let short = capture("已定位喔呐，正在处置故障。")
        let vague = capture("已定位根本原因，正在推进修复。")
        let good = capture("Atlas 账单导出已定位游标偏移，正在修复页码换算。")
        var legacy = RecallState(captures: [incomplete, short, vague, good])
        let engine = MemoryKnowledgeEngine()
        legacy.memoryKnowledge = engine.reconcile(legacy, force: true)
        let files = MatterMemoryEngine().files(in: legacy)
        try expect(files.count == 1 && files[0].title == "Atlas 账单导出",
            "自动主题不能跨逗号把泛指原因和状态拼成名称，也不能把短乱码当成事情")
        try expect(files[0].latest.detail == "Atlas 账单导出已定位游标偏移，正在修复页码换算。",
            "收紧标题解析时截断了有明确对象的完整进展")
        var phantom = legacy.memoryKnowledge.claims.first { $0.kind == .event }!
        phantom.id = UUID(); phantom.key = phantom.id.uuidString; phantom.subjectID = "legacy-ambiguous-topic"
        phantom.title = "故障原因,正在实施修复"; phantom.content = incomplete.ocrText
        phantom.evidence[0].captureID = incomplete.id
        phantom.evidence[0].quote = incomplete.ocrText
        phantom.evidence[0].sourceVersion = MemoryKnowledgeEngine.version(of: incomplete)
        legacy.memoryKnowledge.claims.append(phantom)
        legacy.memoryKnowledge.organizationVersion = nil
        legacy.memoryKnowledgeSettings.automaticOrganization = false
        let staleAnswer = ConversationMessage(role: .assistant, content: "旧的含糊主题结论", citations: [incomplete.id])
        let goodAnswer = ConversationMessage(role: .assistant, content: "Atlas 账单导出已定位游标偏移", citations: [good.id])
        legacy.messages = [staleAnswer, goodAnswer]
        try expect(engine.files(in: legacy) == nil && MatterMemoryEngine().files(in: legacy).count == 1,
            "规则升级后继续使用未更新的旧主题缓存")
        let plan = MemoryRetrievalEngine().plan(question: phantom.title, state: legacy, fallback: [])
        try expect(plan.sourceIDs[phantom.id] == nil, "后台暂停期间旧规则事实仍被直接当成回答依据")
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: storage.stateURL, options: .atomic)
        let store = try FileMemoryStore(storage: storage)
        try await store.organizeMemory(force: true)
        let rebuilt = await store.snapshot()
        try expect(rebuilt.memoryKnowledge.organizationVersion == MemoryKnowledgeEngine.organizationVersion
            && !rebuilt.memoryKnowledge.claims.contains { $0.id == phantom.id },
            "手动重新整理未重建持久化事实，旧错误主题仍在缓存")
        try expect(!rebuilt.messages.contains { $0.id == staleAnswer.id } && rebuilt.messages.contains { $0.id == goodAnswer.id },
            "重新整理没有撤回错误主题的派生结论，或误删了有效结论")
        try expect(rebuilt.captures.map(\.ocrText) == legacy.captures.map(\.ocrText), "重新整理改写了原始证据")
        let reopened = try FileMemoryStore(storage: storage)
        let reopenedState = await reopened.snapshot()
        try expect(MatterMemoryEngine().files(in: reopenedState).count == 1, "重启又读回了旧错误主题")
        legacy.memoryKnowledgeSettings.automaticOrganization = true
        try encoder.encode(legacy).write(to: storage.stateURL, options: .atomic)
        let migrated = try FileMemoryStore(storage: storage)
        let migratedState = await migrated.snapshot()
        try expect(migratedState.memoryKnowledge.organizationVersion == MemoryKnowledgeEngine.organizationVersion
            && !migratedState.messages.contains { $0.id == staleAnswer.id }
            && migratedState.messages.contains { $0.id == goodAnswer.id },
            "启动时没有迁移旧规则并只撤回受影响的结论")
    }
}
