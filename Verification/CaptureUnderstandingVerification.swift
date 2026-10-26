import Foundation
import RecallKit

/// Fabricated records and deterministic model responses. These are contract regressions,
/// not a claim of real-world OCR/model accuracy.
enum CaptureUnderstandingVerification {
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    private struct Stub: LLMResponding {
        let draft: String
        let audit: String
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            guard [.captureUnderstanding, .captureUnderstandingAudit].contains(request.purpose),
                  request.context.count == 1, request.context[0].imageRelativePath == nil,
                  request.recentMessages.isEmpty else { throw Failure(message: "后台理解发送了多余上下文或使用了错误任务类型") }
            return LLMAnswer(content: request.purpose == .captureUnderstanding ? draft : audit, citedCaptureIDs: [])
        }
    }
    private struct Fixture {
        let storage: RecallStorage
        let store: FileMemoryStore
        let source: CaptureRecord
        let config = LLMConfiguration(provider: .openAICompatible, apiKey: "verification-placeholder")
        let privacy = PrivacySettings(cloudUseEnabled: true)
    }
    private static func fixture(_ text: String = "[聊天·自己] 我会在明天补充 Atlas 导出分页测试并提交评审。") async throws -> Fixture {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-understanding-" + UUID().uuidString))
        let store = try FileMemoryStore(storage: storage)
        let source = CaptureRecord(eventTemplate: .workCheckpoint, sourceAppName: "合成测试聊天",
            sourceBundleIdentifier: "example.synthetic-chat", windowTitle: "Atlas 会话", contentHash: UUID().uuidString,
            ocrText: text, textOrigin: .screenOCR)
        let f = Fixture(storage: storage, store: store, source: source)
        try await store.addCapture(source)
        try await store.updatePrivacy(f.privacy); try await store.updateLLMConfiguration(f.config)
        var settings = CaptureUnderstandingSettings(); settings.enabled = true
        settings.enabledSince = source.createdAt.addingTimeInterval(-1)
        try await store.updateCaptureUnderstandingSettings(settings)
        _ = try await store.enqueueCaptureUnderstanding(captureID: source.id)
        return f
    }
    private static func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self) }
    private static func fact(_ page: UnderstandingPage, kind: String = "commitment", speaker: String = "user", actor: String = "user",
                             status: String = "pending", subject: String = "补充 Atlas 导出分页测试", detail: String = "补齐分页边界用例后提交评审。",
                             quote: String? = nil, condition: String? = nil) -> [String: Any] {
        let block = page.blocks.first { !$0.contextOnly }!
        return ["id": "f1", "subject": subject, "detail": detail, "kind": kind, "speaker": speaker, "actor": actor,
                "status": status, "condition": condition as Any? ?? NSNull(), "eventTime": NSNull(), "deadline": NSNull(),
                "evidence": [["blockID": block.id, "quote": quote ?? block.text]]]
    }
    private static func responder(_ page: UnderstandingPage, facts: [[String: Any]], accepted: [String]? = nil,
                                  omitCoverage: Bool = false, auditIDs: [String]? = nil) throws -> Stub {
        let used = Set(facts.flatMap { ($0["evidence"] as? [[String: String]] ?? []).compactMap { $0["blockID"] } })
        let primary = page.blocks.filter { !$0.contextOnly }.map(\.id)
        let coverage = omitCoverage ? [] : primary.map { ["blockID": $0, "disposition": used.contains($0) ? "fact" : "noise"] }
        return try Stub(draft: json(["facts": facts, "coverage": coverage]),
            audit: json(["acceptedFactIDs": accepted ?? facts.compactMap { $0["id"] as? String }, "checkedBlockIDs": auditIDs ?? primary]))
    }
    private static func analyze(_ page: UnderstandingPage, facts: [[String: Any]], accepted: [String]? = nil) async throws -> UnderstandingPageResult {
        try await CaptureUnderstandingEngine.understand(page, responder: responder(page, facts: facts, accepted: accepted), beforeCall: {})
    }
    private static func rejected(_ operation: () async throws -> Void) async throws {
        do { try await operation(); throw Failure(message: "缺乏依据或过期的整理结果被接受") }
        catch is CaptureUnderstandingError { }
    }
    private static func claim(_ f: Fixture) async throws -> (CaptureUnderstandingJob, UnderstandingPage) {
        guard let job = try await f.store.claimCaptureUnderstanding() else { throw Failure(message: "有效后台任务未被领取") }
        return (job, try await f.store.captureUnderstandingPage(job))
    }
    @discardableResult
    private static func finish(_ f: Fixture, facts: (UnderstandingPage) -> [[String: Any]]) async throws -> RecallState {
        let (job, page) = try await claim(f)
        let result = try await analyze(page, facts: facts(page))
        try await f.store.finishCaptureUnderstandingPage(job, result: result, configuration: f.config, privacy: f.privacy)
        return await f.store.snapshot()
    }

    static func run() async throws {
        try defaultsAndMigration()
        try fullTextAndConversationBoundaries()
        try await rolesAndReferences()
        try await quoteAndCoverageGates()
        try await independentAudit()
        try await conditionalAndCompletedWork()
        try await privacyAndPause()
        try await durabilityAndRetry()
        try await pageCheckpointAndModelChange()
        try await sharedMeaningAndExactEvidence()
        try await validEmptyDoesNotResurrectNoise()
        try await correctionAndSourceLifetime()
        try await dependencyDeletion()
        try await resultRemovalAndBackfill()
        try await eventAndDeadlineTime()
        try perItemSummaryEvidence()
        print("PASS: 16 capture-understanding scenarios (roles, coverage, audit, queue, privacy, deletion and downstream meaning)")
    }
    private static func defaultsAndMigration() throws {
        let legacy = try JSONDecoder().decode(RecallState.self, from: Data("{}".utf8))
        try expect(!legacy.understandingSettings.enabled && legacy.understandingJobs.isEmpty, "旧数据迁移偷偷启用了模型理解")
        let record = CaptureRecord(eventTemplate: .manualMoment, contentHash: "old", ocrText: "旧格式测试记录")
        let decoded = try JSONDecoder().decode(CaptureRecord.self, from: JSONEncoder().encode(record))
        try expect(decoded.understanding == nil && decoded.recognition == nil && decoded.correctedText == nil, "旧来源的新增字段没有安全默认值")
    }
    private static func fullTextAndConversationBoundaries() throws {
        let now = Date.now
        let raw = "[聊天·自己] " + String(repeating: "这一段是合成文档中的完整正文，用于验证分段不能漏掉后半部分。", count: 500) + "尾部唯一事实：我会核对 Atlas 导出空值边界。"
        let source = CaptureRecord(eventTemplate: .workCheckpoint, createdAt: now, sourceBundleIdentifier: "example.chat", windowTitle: "独立会话", contentHash: "long", ocrText: raw)
        let pages = CaptureUnderstandingEngine.pages(for: source.id, in: RecallState(captures: [source]))
        let primary = pages.flatMap(\.blocks).filter { !$0.contextOnly }
        try expect(pages.count > 1 && primary.map(\.text).joined() == raw && Set(primary.map(\.id)).count == primary.count, "长 OCR 的尾部、角色或字符被丢弃/重复消费")
        let anchor = "[聊天·自己] 我已完成 Atlas 导出功能的分页边界测试。"
        let earlier = CaptureRecord(eventTemplate: .workCheckpoint, createdAt: now.addingTimeInterval(-40), sourceBundleIdentifier: "example.chat", windowTitle: "Atlas", contentHash: "a", ocrText: "[聊天·对方] 还要保留空页用例。\n" + anchor)
        var current = earlier; current.id = UUID(); current.createdAt = now; current.ocrText = anchor + "\n[聊天·自己] 我会继续核对空页。"
        var unrelated = earlier; unrelated.id = UUID(); unrelated.windowTitle = "其他会话"; unrelated.ocrText += "\n不应混入的另一个会话。"
        let page = CaptureUnderstandingEngine.pages(for: current.id, in: RecallState(captures: [current, earlier, unrelated]))[0]
        try expect(page.blocks.contains { $0.contextOnly && $0.text.contains("保留空页") }, "相邻会话的必要上下文没有保留")
        try expect(!page.sourceVersions.keys.contains(unrelated.id) && !page.blocks.contains { $0.text.contains("不应混入") }, "不同会话被错误拼接")
        var unknown = current; unknown.textOrigin = .userInput; unknown.ocrText = "[聊天·角色未知] 我会核对空页。"
        try expect(CaptureUnderstandingEngine.blocks(for: unknown)[0].speaker == .unknown, "未知角色被手动来源覆盖")
    }
    private static func rolesAndReferences() async throws {
        for text in ["[聊天·对方] 我会补充 Atlas 导出分页测试并提交评审。", "[聊天·角色未知] 我会补充 Atlas 导出分页测试并提交评审。", "[聊天·自己] [内容·资料] 我会补充 Atlas 导出分页测试并提交评审。"] {
            let source = CaptureRecord(eventTemplate: .manualMoment, contentHash: "role", ocrText: text)
            let page = CaptureUnderstandingEngine.pages(for: source.id, in: RecallState(captures: [source]))[0]
            try await rejected { _ = try await analyze(page, facts: [fact(page)]) }
        }
        var source = CaptureRecord(eventTemplate: .manualMoment, contentHash: "quality", ocrText: "[聊天·自己] 我会补充 Atlas 导出分页测试。")
        source.recognition = CaptureRecognition(lines: [.init(text: "我会补充 Atlas 导出分页测试。", x: 0.2, y: 0.4, width: 0.5, height: 0.04, confidence: 0.2)])
        let page = CaptureUnderstandingEngine.pages(for: source.id, in: RecallState(captures: [source]))[0]
        try expect(page.blocks[0].confidence == 0.2, "OCR 质量信息没有保留")
        try await rejected { _ = try await analyze(page, facts: [fact(page)]) }
    }
    private static func quoteAndCoverageGates() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let (_, page) = try await claim(f)
        try await rejected { _ = try await analyze(page, facts: [fact(page, quote: "原文里不存在的完成结论")]) }
        try await rejected {
            _ = try await CaptureUnderstandingEngine.understand(page, responder: responder(page, facts: [], omitCoverage: true), beforeCall: {})
        }
        try await rejected {
            _ = try await CaptureUnderstandingEngine.understand(page, responder: responder(page, facts: [fact(page)], auditIDs: []), beforeCall: {})
        }
    }
    private static func independentAudit() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let (_, page) = try await claim(f)
        let result = try await analyze(page, facts: [fact(page)], accepted: [])
        try expect(result.facts.isEmpty && result.covered == 1 && result.uncertain == 1, "复核否决的事实仍被保存为准确内容")
    }
    private static func conditionalAndCompletedWork() async throws {
        let f = try await fixture("[聊天·自己] 如果联调通过，我会提交 Atlas 导出修复；目前尚未完成。")
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let (_, page) = try await claim(f)
        try await rejected { _ = try await analyze(page, facts: [fact(page, kind: "event", status: "completed")]) }
        let result = try await analyze(page, facts: [fact(page, condition: "联调通过后")])
        try expect(!result.facts[0].isUserAction && result.facts[0].condition == "联调通过后", "条件性计划被升级为立即待办")
    }
    private static func privacyAndPause() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        try await f.store.updatePrivacy(PrivacySettings(cloudUseEnabled: false))
        let denied = try await f.store.claimCaptureUnderstanding()
        try expect(denied == nil, "未经文本授权就启动后台模型")
        try await f.store.updatePrivacy(f.privacy)
        let (job, page) = try await claim(f)
        let result = try await analyze(page, facts: [fact(page)])
        var settings = CaptureUnderstandingSettings(); settings.enabled = false
        try await f.store.updateCaptureUnderstandingSettings(settings)
        try await rejected { try await f.store.finishCaptureUnderstandingPage(job, result: result, configuration: f.config, privacy: f.privacy) }
        let state = await f.store.snapshot()
        try expect(state.captures[0].understanding == nil && state.understandingJobs[0].lease == nil, "暂停后仍写入模型结果")
    }
    private static func durabilityAndRetry() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let (first, _) = try await claim(f)
        let reopened = try FileMemoryStore(storage: f.storage)
        try await reopened.recoverCaptureUnderstandingJobs()
        let recovered = await reopened.snapshot()
        try expect(recovered.understandingJobs[0].state == .queued && recovered.understandingJobs[0].lease == nil, "退出重启后任务无法恢复")
        let next = try await reopened.claimCaptureUnderstanding()
        try expect(next?.id == first.id && next?.lease != first.lease, "恢复后复用了旧租约")
        if let next { try await reopened.failCaptureUnderstanding(next, changed: false) }
        var time = Date.now.addingTimeInterval(1_000)
        for _ in 0..<1 {
            guard let job = try await reopened.claimCaptureUnderstanding(now: time) else { throw Failure(message: "重试任务丢失") }
            try await reopened.failCaptureUnderstanding(job, changed: false, now: time); time = time.addingTimeInterval(1_000)
        }
        let stopped = await reopened.snapshot()
        try expect(stopped.understandingJobs[0].state == .failed && stopped.captures[0].ocrText == f.source.ocrText, "失败未封顶或改坏原文")
    }
    private static func pageCheckpointAndModelChange() async throws {
        let f = try await fixture(String(repeating: "[聊天·角色未知] 合成文档正文，不足以确认个人行动。\n", count: 80))
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let (job, page) = try await claim(f)
        let result = try await analyze(page, facts: [])
        try await f.store.finishCaptureUnderstandingPage(job, result: result, configuration: f.config, privacy: f.privacy)
        var state = await f.store.snapshot()
        try expect(state.captures[0].understanding == nil && state.understandingJobs[0].nextPage == 1, "半份结果提前公开或断点未持久化")
        let reopened = try FileMemoryStore(storage: f.storage)
        let next = try await reopened.claimCaptureUnderstanding()
        try expect(next?.nextPage == 1, "重启后重复从首段处理")
        var changed = f.config; changed.model = "other-test-model"
        try await reopened.updateLLMConfiguration(changed)
        if let next { try await reopened.failCaptureUnderstanding(next, changed: true) }
        guard let fresh = try await reopened.claimCaptureUnderstanding() else { throw Failure(message: "模型变化后任务未恢复") }
        state = await reopened.snapshot()
        try expect(fresh.nextPage == 0 && state.understandingJobs[0].facts.isEmpty, "切换模型后混合了不同模型的半份结果")
    }
    private static func sharedMeaningAndExactEvidence() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let state = try await finish(f) { [fact($0)] }
        let source = state.captures[0]
        try expect(source.ocrText == f.source.ocrText && source.understanding?.facts.count == 1, "理解覆盖了原文或没有保存结果")
        let reminders = ReminderExtractor().candidates(from: state.captures, existing: [])
        let files = MatterMemoryEngine().files(in: state)
        try expect(reminders.count == 1 && reminders[0].status == .proposed && files.contains { $0.title == reminders[0].title }, "主题与提醒没有共用同一个具体事项，或自动安排了通知")
        let knowledge = MemoryKnowledgeEngine().reconcile(state, force: true)
        let claims = knowledge.claims.filter { $0.kind == .event || $0.kind == .action }
        try expect(!claims.isEmpty && claims.flatMap(\.evidence).allSatisfy { f.source.ocrText.contains($0.quote) }, "生成文字被冒充原文证据")
        let daily = DailySummaryGenerator().sourceRecords(for: source.createdAt, from: [source])
        let chat = ConversationContextManager().plan(history: [], existingSummary: nil, coveredMessageCount: 0, retrievedEvidence: [source])
        try expect(daily[0].ocrText.contains("补充 Atlas 导出分页测试") && chat.evidence[0].ocrText.contains("本人陈述"), "回顾或聊天仍只拿 OCR 前缀")
        try expect(SummaryFeedbackLearning.rawVersion(source) == SummaryFeedbackLearning.rawVersion(f.source), "新增理解结果破坏了旧反馈的原文版本")
    }
    private static func validEmptyDoesNotResurrectNoise() async throws {
        let f = try await fixture("[聊天·自己] 我会在明天打开设置检查网络错误。\n[聊天·角色未知] 网络异常，请检查网络后重试。")
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let state = try await finish(f) { _ in [] }
        try expect(state.captures[0].understanding != nil && state.captures[0].understanding!.facts.isEmpty, "有效空结果触发了失败回退")
        try expect(ReminderExtractor().candidates(from: state.captures, existing: []).isEmpty && MatterMemoryEngine().files(in: state).isEmpty,
            "模型判定无行动后，关键词解析又复活了噪声")
    }
    private static func correctionAndSourceLifetime() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        _ = try await finish(f) { [fact($0)] }
        let replacement = "[聊天·对方] 我会补充 Atlas 导出分页测试并提交评审。"
        try await f.store.correctCaptureText(f.source.id, text: replacement)
        var state = await f.store.snapshot()
        try expect(state.captures[0].ocrText == f.source.ocrText && state.captures[0].understanding == nil && state.correctedForAnalysis().captures[0].ocrText == replacement,
            "更正没有使旧理解失效，或覆盖了原始 OCR")
        try expect(state.understandingJobs[0].state == .queued, "更正后没有重新核对入口")
        let (job, page) = try await claim(f)
        let result = try await analyze(page, facts: [])
        _ = try await f.store.deleteCapture(id: f.source.id)
        try await rejected { try await f.store.finishCaptureUnderstandingPage(job, result: result, configuration: f.config, privacy: f.privacy) }
        state = await f.store.snapshot()
        try expect(state.captures.isEmpty && state.understandingJobs.isEmpty, "删除后后台任务仍持有原文或可恢复旧结果")
    }
    private static func dependencyDeletion() async throws {
        let f = try await fixture("[聊天·自己] 我会补充 Atlas 导出分页测试并提交评审。")
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        var earlier = f.source; earlier.id = UUID(); earlier.createdAt = f.source.createdAt.addingTimeInterval(-30)
        earlier.ocrText += "\n[聊天·对方] 保留空页的边界用例。"
        try await f.store.addCapture(earlier)
        _ = try await finish(f) { [fact($0)] }
        let before = await f.store.snapshot()
        try expect(before.captures.first { $0.id == f.source.id }?.understanding?.sourceVersions[earlier.id] != nil, "上下文依赖没有登记")
        _ = try await f.store.deleteCapture(id: earlier.id)
        let after = await f.store.snapshot()
        try expect(after.captures[0].understanding == nil && after.understandingJobs[0].facts.isEmpty, "删除上下文后仍保留依赖它的理解")
    }
    private static func resultRemovalAndBackfill() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        _ = try await finish(f) { [fact($0)] }
        try await f.store.removeCaptureUnderstanding(f.source.id)
        _ = try await f.store.enqueueCaptureUnderstanding()
        let state = await f.store.snapshot()
        try expect(state.captures[0].ocrText == f.source.ocrText && state.understandingJobs[0].state == .discarded, "删除整理结果后自动重新生成了它")
        var old = f.source; old.id = UUID(); old.createdAt = .now.addingTimeInterval(-100 * 86_400)
        try await f.store.addCapture(old)
        let count = try await f.store.enqueueCaptureUnderstanding(since: .now.addingTimeInterval(-30 * 86_400))
        try expect(count == 0, "启用/近30天整理上传了更早归档或已删除的理解")
    }
    private static func eventAndDeadlineTime() async throws {
        let f = try await fixture("[聊天·自己] 2020-01-02 我已完成 Atlas 导出测试。")
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let state = try await finish(f) { page in
            var value = fact(page, kind: "event", status: "completed", subject: "Atlas 导出测试完成", detail: "已完成分页边界测试。")
            value["eventTime"] = ["text": "2020-01-02", "evidence": ["blockID": page.blocks[0].id, "quote": page.blocks[0].text]]
            return [value]
        }
        let event = MatterMemoryEngine().files(in: state)[0].events[0]
        try expect(event.eventAt != nil && event.date < f.source.createdAt && event.recordedAt == f.source.createdAt, "采集时间替代了原文明确的历史发生日期")
        try expect(ReminderExtractor().candidates(from: state.captures, existing: []).isEmpty, "历史完成日期变成待办截止时间")
    }
    private static func perItemSummaryEvidence() throws {
        let first = UUID(), second = UUID()
        let text = """
        {"headline":"修复导出与账单","progress":[{"title":"导出测试完成","detail":"分页边界通过","evidenceIndices":[1]},{"title":"账单修复完成","detail":"空值用例通过","evidenceIndices":[2]},{"title":"没有依据的成果","detail":"不应该出现"}],"actions":[],"insights":[]}
        """
        let items = DailySummaryItemParser.itemsFromModelResponse(text, defaultEvidenceIDs: [first, second], strictEvidence: true) ?? []
        try expect(items.first { $0.title == "导出测试完成" }?.evidenceIDs == [first]
            && items.first { $0.title == "账单修复完成" }?.evidenceIDs == [second]
            && !items.contains { $0.title == "没有依据的成果" }, "每日回顾仍把整份请求的全部来源冒充每个结论的依据")
    }
}
