import Foundation
import RecallKit

enum RecordCoverageVerification {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    private static let body = "Atlas 集成排查记录：资料讨论了请求进入服务之后的参数校验、缓存读取和数据库查询三个环节。不同环境中的配置可能存在差异，需要先核对配置来源，再判断异常出现的位置。这是保存的讨论内容，尚未记录由谁执行检查，也没有独立的验收结果。"
    private static func source(_ text: String = body, at date: Date = .now.addingTimeInterval(-86_400)) -> CaptureRecord {
        CaptureRecord(eventTemplate: .manualMoment, createdAt: date, sourceAppName: "合成测试浏览器",
            sourceBundleIdentifier: "test.coverage", windowTitle: "Atlas 集成排查资料", contentHash: UUID().uuidString,
            ocrText: text, textOrigin: .screenOCR)
    }
    static func run() async throws {
        try await unownedContentReview()
        try await recordDatesAndNoise()
        try largeArchiveDeduplication()
    }
    private static func unownedContentReview() async throws {
        let record = source()
        var state = RecallState(captures: [record])
        state.memoryKnowledge = MemoryKnowledgeEngine().reconcile(state, force: true)
        let claims = state.memoryKnowledge.claims
        try expect(claims.contains { $0.kind == .reference } && !claims.contains { $0.kind.isPersonal || $0.kind == .event || $0.kind == .experience },
            "有实质内容但未标角色的旧记录应形成线索，不能变成本人行动、偏好或经验")
        try expect(MatterMemoryEngine().files(in: state).isEmpty, "资料线索被混入了本人进行中事项")
        let now = Date.now, period = ReviewPeriod.make(.recentSeven, at: now)
        let report = try await WeeklyReviewEngine().generate(in: state, period: period, template: ReviewTemplate(kind: .personal), now: now)
        try expect(!report.items.isEmpty && report.items.allSatisfy { $0.section == .notes }
            && report.sourceIDs == Set([record.id]) && report.digestRows.isEmpty && report.items[0].excerpts[0].text.contains("归属与实际状态未确认"),
            "保存资料必须保留在依据中，不可在没有可靠小结时冒充用户进展")
        let plan = MemoryRetrievalEngine().plan(question: "最近七天保存了哪些内容，总结一下", state: state, fallback: [])
        try expect(plan.sourceIDs.values.contains { $0.contains(record.id) }
            && plan.evidence.contains { $0.ocrText.contains("不能当作用户成果") }, "问一问未读取带归属边界的记录线索")
        let summary = MemoryOrganizationSummary(state: state)
        try expect(summary.records == 1 && summary.references == 1 && summary.experiences == 0
            && summary.agreements == 0 && summary.attributedRecords == 0, "整理结果计数混淆了原始记录与经验")
        state.privacy.cloudUseEnabled = true
        let composed = try await WeeklyReviewEngine().generate(in: state, period: period,
            template: ReviewTemplate(kind: .personal), responder: ReferenceResponder(), now: now)
        try expect(composed.modelAssisted && composed.items.first?.narrative != nil,
            "未标角色的有效记录没有进入模型整理与独立核对流程")
        let root = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root.rootURL) }
        let store = try FileMemoryStore(storage: root)
        try await store.addCapture(record); try await store.organizeMemory(force: true)
        let indexed = await store.snapshot()
        let claim = indexed.memoryKnowledge.claims.first { $0.kind == .reference }!
        try await store.retireMemory(id: claim.id)
        try await store.organizeMemory(force: true)
        try await store.organizeMemory(force: true)
        let retired = await store.snapshot()
        try expect(!WeeklyReviewEngine.sourcesUnchanged(report, in: retired), "停用线索后旧回顾仍可作为有效来源提交")
        try expect(WeeklyReviewEngine().topics(in: retired).isEmpty, "停用的记录线索又从原文回退中复活")
        let hidden = MemoryRetrievalEngine().plan(question: "Atlas 集成排查资料", state: retired, fallback: [record])
        try expect(hidden.evidence.isEmpty, "停用的记录线索绕过状态检查进入问答")
        _ = try await store.deleteCapture(id: record.id)
        let deleted = await store.snapshot()
        try expect(deleted.memoryKnowledge.claims.isEmpty && deleted.memoryKnowledge.entities.isEmpty, "删除来源残留资料线索或主题")
    }
    private struct ReferenceResponder: LLMResponding {
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            let topics = try request.context.map { record -> [String: Any] in
                guard let topic = try JSONSerialization.jsonObject(with: Data(record.ocrText.utf8)) as? [String: Any],
                      (topic["evidenceClass"] as? String)?.contains("归属未确认") == true else {
                    throw Failure(message: "模型未收到记录线索的归属边界")
                }
                return topic
            }
            let output: [String: Any]
            if request.purpose == .weeklyComposition {
                output = ["items": topics.map { topic in
                    ["topicID": topic["topicID"]!, "title": "Atlas 集成排查资料",
                     "summary": "保存的内容讨论了参数校验、缓存读取和配置来源核对，尚未记录执行者与独立验收结果。",
                     "evidenceIDs": topic["requiredEvidenceIDs"]!] as [String: Any]
                }]
            } else if request.purpose == .weeklyAudit {
                output = ["checks": topics.map { topic in
                    ["topicID": topic["topicID"]!, "supported": true, "correctAttribution": true,
                     "preservesState": true, "coversKeyFacts": true] as [String: Any]
                }]
            } else { throw Failure(message: "记录回顾误走其他模型用途") }
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    private static func recordDatesAndNoise() async throws {
        let now = Date.now, old = now.addingTimeInterval(-20 * 86_400)
        let saved = source(at: old)
        let empty = source("", at: old)
        let noise = source(String(repeating: "消息\n通讯录\n工作台\n微盘\n智能助理\n12:30\n", count: 20), at: old)
        let state = RecallState(captures: [saved, empty, noise])
        let coverage = ReviewRecordCoverage(state: state, period: .make(.recentSeven, at: now))
        try expect(coverage.totalRecords == 3 && coverage.periodRecords == 0 && coverage.latestRecordAt == old,
            "全库记录数被当成所选日期内记录数，或未提供最近的真实记录日期")
        try expect(MemoryReferenceEngine().files(in: RecallState(captures: [noise, empty])).isEmpty,
            "只有菜单、时间或空文字的截图制造了资料主题")
        let period = ReviewPeriod(start: old.addingTimeInterval(-86_400), end: old.addingTimeInterval(86_400))
        let report = try await WeeklyReviewEngine().generate(in: state, period: period, template: ReviewTemplate(kind: .personal), now: now)
        try expect(report.sourceIDs == Set([saved.id]), "调整到有记录日期后仍空白，或菜单噪声进入了回顾")
        var excluded = state; excluded.privacy.excludedBundleIdentifiers.insert("test.coverage")
        try expect(WeeklyReviewEngine().topics(in: excluded).isEmpty, "被排除来源借记录线索进入了回顾")
        try expect(ReviewRecordCoverage(state: excluded, period: period).totalRecords == 0, "覆盖诊断泄露了被排除来源")
    }
    private static func largeArchiveDeduplication() throws {
        let sameDay = Calendar.current.startOfDay(for: .now).addingTimeInterval(1)
        let captures = (0..<6333).map { _ in source(at: sameDay) }
        let state = RecallState(captures: captures)
        let files = MemoryReferenceEngine().files(in: state)
        try expect(files.count == 1 && files[0].events.count == 1 && files[0].evidenceIDs.count == 6333,
            "数千条重复截图制造了数千份摘要，或合并时丢失原始来源")
        try expect(MemoryOrganizationSummary(state: state).records == 6333, "整理诊断未显示真实检查规模")
    }
}
