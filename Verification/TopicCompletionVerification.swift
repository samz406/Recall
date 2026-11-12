import Foundation
import RecallKit

@MainActor
enum TopicCompletionVerification {
    private struct Failure: LocalizedError { let errorDescription: String? }
    private static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(errorDescription: message) }
    }

    static func run() async throws {
        let now = Date.now
        let first = KnowledgeProjectionVerification.capture("请核对 Atlas 页面验收和 Nova 账单导出。", at: now.addingTimeInterval(-172_800), title: "合成对话")
        let second = KnowledgeProjectionVerification.capture("这两项仍需要继续核对。", at: now.addingTimeInterval(-86_400), title: "合成对话")
        let summaries = [first, second].map { source -> DailySummary in
            var summary = KnowledgeProjectionVerification.review(day: Calendar.current.startOfDay(for: source.createdAt), evidence: [source.id],
                topic: "Atlas 页面验收", quotes: [DailyLedgerQuote(text: source.ocrText, sourceIDs: [source.id], speaker: "user")])
            summary.ledger[0].status = "pending"
            summary.ledger[0].section = "actions"
            summary.ledger.append(DailyMatterLedgerEntry(topic: "Nova 账单导出", kind: .matter, status: "inProgress", section: "progress",
                title: "继续核对 Nova 账单导出", detail: "仍在检查分页边界。", ownedByUser: true,
                quotes: [DailyLedgerQuote(text: source.ocrText, sourceIDs: [source.id], speaker: "user")], evidenceIDs: [source.id], occurredAt: source.createdAt))
            return summary
        }
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("topic-completion-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(RecallState(captures: [first, second], dailySummaries: summaries)).write(to: storage.stateURL)
        let store = try FileMemoryStore(storage: storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
        let before = await store.snapshot(), engine = MatterMemoryEngine(), cache = MemoryWorkspaceCache()
        guard let target = engine.files(in: before).first(where: { $0.title == "Atlas 页面验收" }) else { throw Failure(errorDescription: "未建立合成回顾主题") }
        let originalProjection = try await cache.prepare(in: before)
        let sourceVersion = CaptureUnderstandingEngine.sourceVersion(before.captures[0], in: before)
        let correction = MatterCorrection(evidenceIDs: target.evidenceIDs, kind: .completed, text: target.title, topicID: target.id)
        try await store.saveMatterCorrection(correction)
        try await store.saveMatterCorrection(correction)
        let saved = await store.snapshot(), projection = try await cache.prepare(in: saved)
        let immediate = originalProjection.applyingTopicCompletions(in: saved)
        try expect(immediate.matters == projection.matters && immediate.revision != originalProjection.revision,
            "卡片完成的即时投影与完整重建结果不一致")
        try expect(immediate.applyingTopicCompletions(in: saved).revision == immediate.revision
            && immediate.sources == originalProjection.sources
            && immediate.review.coverage(in: .make(.recentSeven)).textRecords == originalProjection.review.coverage(in: .make(.recentSeven)).textRecords,
            "完成状态补丁重复重建、改变来源或破坏回顾索引")
        try expect(projection.matters.first { $0.id == target.id }?.latest.detail == target.latest.detail
            && projection.matters.first { $0.id == target.id }?.latest.quotes == target.latest.quotes,
            "完成状态覆盖了原有进展或引用")
        try expect(TopicReading(file: projection.matters.first { $0.id == target.id }!).overview != "用户已标记完成：" + target.title,
            "完成主题详情仍只有状态文案")
        try expect(saved.matterCorrections.count == 1, "重复完成写入了重复更正")
        try expect(saved.captures == before.captures && saved.dailySummaries == before.dailySummaries, "完成主题删除或修改了原始记录/每日回顾")
        try expect(saved.correctedForAnalysis().dailySummaries == before.dailySummaries, "分析视图仍撤回已生成回顾")
        try expect(CaptureUnderstandingEngine.sourceVersion(saved.captures[0], in: saved) == sourceVersion, "完成主题使原始理解失效")
        try expect(projection.revision != originalProjection.revision && projection.matters.first { $0.id == target.id }?.latest.status == .completed,
            "缓存未刷新，完成主题仍留在进行中")
        let dailyTopic = DailyKnowledgeEngine().matterFiles(in: saved).first { $0.id == target.id }
        try expect(dailyTopic?.latest.status == .completed && dailyTopic?.latest.nextAction == nil,
            "每日回顾投影保留了已完成主题的待办")
        try expect(engine.files(in: saved).first { $0.title == "Nova 账单导出" }?.latest.status == .progressed, "共享截图的另一个主题被误标完成")
        try await store.organizeMemory(force: true)
        let organized = await store.snapshot()
        try expect(organized.dailySummaries == before.dailySummaries && engine.files(in: organized).first { $0.id == target.id }?.latest.status == .completed,
            "重新整理覆盖完成状态或移除了回顾")
        try expect(organized.memoryKnowledge.claims.contains { $0.status == .completed && $0.evidence.contains { $0.correctedBy == correction.id } },
            "完成状态没有用户更正来源")
        let reopened = try FileMemoryStore(storage: storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
        let restored = await reopened.snapshot()
        try expect(engine.files(in: restored).first { $0.id == target.id }?.latest.status == .completed, "重启丢失了完成标记")

        // Future evidence can reopen the topic without rewriting its saved history.
        var changed = restored
        let update = try ManualMatterNote(title: target.title, detail: "新增验收项，继续核对。", status: .progressed, eventAt: now).capture(recordedAt: now)
        changed.captures.append(update)
        try expect(engine.files(in: changed).first { $0.id == target.id }?.latest.status == .progressed, "新进展被旧完成标记永久压住")
        let group = MemoryTopicGroup(title: "合成项目验收", memberIDs: engine.files(in: before).map(\.id))
        var grouped = before; grouped.topicGroups = [group]
        let groupedFile = engine.files(in: grouped)[0]
        grouped.matterCorrections = [MatterCorrection(evidenceIDs: groupedFile.evidenceIDs, kind: .completed, text: groupedFile.title, topicID: groupedFile.id)]
        try expect(engine.files(in: grouped)[0].latest.status == .completed, "合并主题无法完成")

        try await reopened.removeMatterCorrection(id: correction.id)
        let undone = await reopened.snapshot()
        try expect(engine.files(in: undone).first { $0.id == target.id }?.latest.status == .pending && undone.dailySummaries == before.dailySummaries,
            "撤销完成未恢复原状态或删除了回顾")
        try await reopened.organizeMemory(force: true)
        let reorganized = await reopened.snapshot()
        try expect(engine.files(in: reorganized).first { $0.id == target.id }?.latest.status == .pending, "撤销后重建仍显示完成")

        // Legacy corrections without a topic scope still decode.
        var object = try JSONSerialization.jsonObject(with: encoder.encode(correction)) as! [String: Any]
        object.removeValue(forKey: "topicID")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(MatterCorrection.self, from: JSONSerialization.data(withJSONObject: object))
        try expect(legacy.topicID == nil && !legacy.isTopicCompletion, "旧版本更正记录不兼容")
        print("PASS: topic completion refreshes projections, persists across restart/rebuild, preserves daily reviews/shared topics, supports undo/new evidence and legacy corrections")
    }
}
