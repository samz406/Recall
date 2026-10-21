import Foundation
import CryptoKit
import RecallKit

@MainActor
enum MemoryKnowledgeVerification {
    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }
    static func expect(_ condition: Bool, _ text: String) throws { if !condition { throw Failure(text: text) } }
    static func capture(_ text: String, day: Date = .now, title: String = "账单导出") -> CaptureRecord {
        CaptureRecord(eventTemplate: .manualMoment, createdAt: day, sourceAppName: "合成记录",
            sourceBundleIdentifier: "test.memory", windowTitle: title, contentHash: UUID().uuidString,
            ocrText: text, textOrigin: .screenOCR)
    }
    static func fixture() throws -> (RecallStorage, FileMemoryStore) {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return (storage, try FileMemoryStore(storage: storage))
    }
    static func run() async throws {
        try sourceOwnership()
        try await scopedAgreements()
        try await aliasRetrieval()
        try await organizationLifecycle()
        try await retention()
        try await dependencyRetraction()
        try await canonicalReviews()
        try experiences()
        try incrementalIndex()
    }
    static func sourceOwnership() throws {
        let day = Date.now.addingTimeInterval(-86_400)
        let first = capture("[聊天·自己] 账单导出已定位，需要检查分页边界。\n[聊天·自己] 通知订阅已验证通过。\n[聊天·对方] 我喜欢详细解释。\n[聊天·角色未知] 我每天跑步。\n[内容·资料] 我希望获得更多收益。", day: day)
        let repeated = capture(first.ocrText)
        var state = RecallState(captures: [first, repeated])
        let engine = MemoryKnowledgeEngine()
        let knowledge = engine.reconcile(state, force: true)
        let events = knowledge.claims.filter { $0.kind == .event }
        try expect(Set(events.map(\.subjectID)).count == 2, "同屏多个事项没有进入统一事实层")
        try expect(!knowledge.claims.contains { $0.kind.isPersonal }, "他人、未知角色或资料进入了用户画像")
        try expect(events.allSatisfy { $0.sourceIDs.count == 2 && $0.date == day }, "重复截图制造了独立事实或移动首次记录时间")
        try expect(events.allSatisfy { !$0.evidence.isEmpty && $0.evidence.allSatisfy { !$0.quote.isEmpty && $0.speaker == "自己" && !$0.sourceVersion.isEmpty } }, "事实缺少原文、角色或版本")
        state.memoryKnowledge = knowledge
        let second = engine.reconcile(state, force: true)
        try expect(Set(second.claims.map(\.id)) == Set(knowledge.claims.map(\.id)), "重复整理改变事实标识")
        state.matterCorrections = [MatterCorrection(evidenceIDs: [first.id, repeated.id], kind: .notMine)]
        try expect(engine.reconcile(state).claims.isEmpty, "归属更正没有撤回衍生事实")
        let correction = MatterCorrection(evidenceIDs: [first.id, repeated.id], kind: .completed, text: "账单导出")
        state.matterCorrections = [correction]
        let corrected = engine.reconcile(state, force: true)
        try expect(corrected.claims.contains { $0.evidence.contains { $0.correctedBy == correction.id } }, "用户更正被冒充为截图原话，缺少更正来源")
    }
    static func scopedAgreements() async throws {
        let (storage, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let assistant = MemoryAssistant(store: store)
        _ = try await assistant.ask("记住：以后工作周报简洁一点")
        var state = await store.snapshot()
        try expect(state.memoryKnowledge.claims.contains { $0.explicit && $0.scope == .work && $0.usable() }, "明确约定没有当场生效")
        _ = try await assistant.ask("记住：以后工作周报详细一点")
        state = await store.snapshot()
        let work = state.memoryKnowledge.claims.filter { $0.explicit && $0.scope == .work }
        try expect(work.filter { $0.usable() }.count == 1 && work.contains { $0.state == .superseded }, "新约定没有替代同范围的旧版本")
        let id = UUID()
        guard let single = MemoryDirective.parse("这次简洁一点", conversationID: id) else { throw Failure(text: "未识别本次会话约定") }
        _ = try await store.remember(single)
        state = await store.snapshot()
        let reader = MemoryRetrievalEngine()
        let here = reader.preferenceContext(question: "工作周报", claims: state.memoryKnowledge.claims, conversationID: id) ?? ""
        let elsewhere = reader.preferenceContext(question: "生活回顾", claims: state.memoryKnowledge.claims, conversationID: UUID()) ?? ""
        try expect(here.contains("本次会话") && here.contains("详细"), "没有保留本次约定优先和任务范围")
        try expect(!elsewhere.contains("简洁") && !elsewhere.contains("工作周报"), "工作或本次约定污染了其他范围")
        try expect(MemoryDirective.parse("以后如何解决数据库死锁") == nil, "普通提问被误保存为长期约定")
        try await store.addCapture(capture("[聊天·自己] 我喜欢苹果。\n[聊天·自己] 我不喜欢苹果。"))
        try await store.organizeMemory()
        state = await store.snapshot()
        let conflicts = state.memoryKnowledge.claims.filter { $0.kind == .preference && !$0.explicit }
        try expect(conflicts.count == 2 && conflicts.allSatisfy { $0.state == .conflicted }, "矛盾偏好被静默合并为稳定结论")
        _ = try await assistant.ask("记住：妙妙的生日是九月十八日")
        state = await store.snapshot()
        try expect(state.memoryKnowledge.entities.contains { $0.kind == "person" && $0.name == "妙妙" }, "明确人物事实没有形成可检索人物")
        let acknowledgement = try await assistant.ask("这次简洁一点")
        try expect(acknowledgement.content.contains("本次会话"), "本次表达约定没有本地返回执行结果")
        _ = try await assistant.ask("/clear")
        let cleared = await store.snapshot()
        try expect(cleared.memoryKnowledge.claims.filter { $0.scope == .conversation }.allSatisfy { $0.state == .expired }, "清空会话后本次偏好仍有效")
    }
    static func aliasRetrieval() async throws {
        let (storage, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let start = calendar.startOfDay(for: .now)
        var records: [CaptureRecord] = []
        for i in 0..<7 {
            let day = calendar.date(byAdding: .day, value: -i, to: start)!.addingTimeInterval(60)
            let record = capture("[聊天·自己] 账单导出第\(i)轮边界修复已验证通过。", day: day)
            records.append(record); try await store.addCapture(record)
        }
        try await store.organizeMemory()
        var state = await store.snapshot()
        guard let entity = state.memoryKnowledge.entities.first else { throw Failure(text: "没有可维护别名的事项") }
        try await store.updateMemoryAliases(entityID: entity.id, aliases: ["报表下载", "账单下载"])
        state = await store.snapshot()
        let reader = MemoryRetrievalEngine()
        let alias = reader.plan(question: "上次报表下载怎么解决", state: state, fallback: [])
        try expect(alias.passes == 2 && !alias.evidence.isEmpty, "别名没有触发原文补查")
        try expect(alias.sourceIDs.values.flatMap { $0 }.contains(records[0].id), "补查结果没有原始来源映射")
        let week = reader.plan(question: "最近七天做了哪些事情", state: state, fallback: [], now: start.addingTimeInterval(3_600))
        let days = Set(week.evidence.map { calendar.startOfDay(for: $0.createdAt) })
        try expect(days.count == 7, "统一事实检索丢失跨日覆盖")
        state.privacy.excludedBundleIdentifiers = ["test.memory"]
        try expect(reader.plan(question: "报表下载", state: state, fallback: records).evidence.isEmpty, "被排除的来源经派生事实或补查重新进入上下文")
        guard let deleted = try await store.moveCapturesToRecentlyDeleted(ids: Set(records.map(\.id)), reason: .noLongerNeeded, suppressSimilar: false) else {
            throw Failure(text: "未创建记忆删除快照")
        }
        _ = try await store.restoreRecentlyDeleted(id: deleted.id)
        let restored = await store.snapshot()
        try expect(restored.memoryKnowledge.entities.contains { $0.aliases.contains("报表下载") }, "恢复原始记录后丢失用户提供的别名")
        try expect(!reader.plan(question: "报表下载", state: restored, fallback: []).evidence.isEmpty, "恢复后统一记忆没有立即重新可读")
        var cloudState = restored
        cloudState.privacy.cloudUseEnabled = true
        let semantic = try await MemorySemanticLookup().topics(for: "上次那个表格取不下来是怎么解决的", in: cloudState,
            responder: TopicProbe(name: entity.name))
        try expect(semantic == [entity.id], "语义补查没有限定为真实主题 ID")
        let semanticPlan = reader.plan(question: "上次那个表格取不下来是怎么解决的", state: cloudState,
            fallback: [], resolvedEntityIDs: semantic)
        try expect(!semanticPlan.evidence.isEmpty, "语义定位后没有回到本地证据")
        let invalid = try await MemorySemanticLookup().topics(for: "表格下载", in: cloudState,
            responder: TopicProbe(name: "不存在的主题"))
        try expect(invalid.isEmpty, "模型编造的主题进入检索")
    }
    struct TopicProbe: LLMResponding {
        let name: String
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            guard request.purpose == .memoryLookup && request.outputTokenLimit == 600 else { throw Failure(text: "语义定位没有采用专用协议和预算") }
            let text = request.context.map(\.ocrText).joined()
            guard !text.contains("已验证通过") else { throw Failure(text: "语义定位外发了不必要的原始记录") }
            let rows = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] ?? []
            let id = rows.first { $0["name"] as? String == name }?["id"] as? String ?? "invalid-topic"
            return LLMAnswer(content: "{\"topicIDs\":[\"\(id)\"]}", citedCaptureIDs: [])
        }
    }

    static func organizationLifecycle() async throws {
        let (storage, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        var settings = MemoryKnowledgeSettings(); settings.automaticOrganization = false
        try await store.updateMemoryKnowledgeSettings(settings)
        let record = capture("[聊天·自己] 账单导出修复已验证通过。")
        try await store.addCapture(record)
        var state = await store.snapshot()
        try expect(state.memoryKnowledge.claims.isEmpty, "后台暂停后仍自动提升新事实")
        try await store.organizeMemory(force: true)
        state = await store.snapshot()
        try expect(!state.memoryKnowledge.claims.isEmpty, "手动整理没有处理待整理记录")
        let reloaded = try FileMemoryStore(storage: storage)
        let restored = await reloaded.snapshot()
        try expect(restored.memoryKnowledge.claims.map(\.id) == state.memoryKnowledge.claims.map(\.id), "重启丢失事实或整理检查点")
        _ = try await reloaded.deleteCapture(id: record.id)
        let removed = await reloaded.snapshot()
        try expect(removed.memoryKnowledge.claims.isEmpty, "后台暂停阻止了删除撤回")
    }
    static func retention() async throws {
        let (storage, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let old = Date.now.addingTimeInterval(-100 * 86_400)
        var record = capture("[聊天·自己] 账单导出修复已验证通过。", day: old)
        record.imageRelativePath = try storage.saveScreenshot(Data([0, 1, 2]), captureID: record.id)
        try await store.addCapture(record)
        let directive = MemoryDirective(content: "工作周报简洁一点", key: "response-length", scope: .work)
        let remembered = try await store.remember(directive, now: old)
        let paths = try await store.prune()
        var state = await store.snapshot()
        try expect(!state.captures.contains { $0.id == record.id }, "到期原始文本没有清理")
        try expect(state.captures.first { $0.id == remembered.id }?.isMemoryEvidenceArchive == true, "明确约定未独立保留最小依据")
        try expect(paths == [record.imageRelativePath!] && state.memoryKnowledge.pendingScreenshotDeletions == paths, "失败清理没有持久化重试队列")
        for path in paths { try storage.deleteScreenshot(relativePath: path) }
        try await store.finishScreenshotCleanup(paths: paths)
        var settings = state.memoryKnowledgeSettings; settings.retainExplicitMemories = false
        try await store.updateMemoryKnowledgeSettings(settings)
        _ = try await store.prune()
        state = await store.snapshot()
        try expect(state.captures.isEmpty && state.memoryKnowledge.claims.isEmpty, "关闭独立保留后仍有到期记忆残留")

        var recent = capture("[聊天·自己] 账单导出修复已验证通过。", day: .now.addingTimeInterval(-8 * 86_400))
        recent.imageRelativePath = try storage.saveScreenshot(Data([3, 4, 5]), captureID: recent.id)
        try await store.addCapture(recent)
        try await store.organizeMemory(force: true)
        state = await store.snapshot()
        let period = ReviewPeriod(start: .now.addingTimeInterval(-9 * 86_400), end: .now)
        var report = try await WeeklyReviewEngine().generate(in: state, period: period, template: ReviewTemplate(kind: .personal))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let oldVersion = SHA256.hash(data: try encoder.encode(recent) + encoder.encode([MatterCorrection]())).map { String(format: "%02x", $0) }.joined()
        report.sourceVersions = [recent.id: oldVersion]
        state.weeklyReports = [report]
        try encoder.encode(state).write(to: storage.stateURL, options: .atomic)
        let reloaded = try FileMemoryStore(storage: storage)
        _ = try await reloaded.prune()
        let pruned = await reloaded.snapshot()
        try expect(pruned.captures.first?.imageRelativePath == nil && pruned.memoryKnowledge.claims.contains { $0.kind == .event && $0.usable() }, "截图到期误删了仍有效的文字事实")
        try expect(pruned.weeklyReports.first?.isReadable == true && pruned.weeklyReports.first?.sourceVersions.values.allSatisfy { $0.hasPrefix("memory2:") } == true, "截图到期或版本升级使旧周回顾失效")
    }
    static func dependencyRetraction() async throws {
        let (storage, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let record = try await store.remember(MemoryDirective(content: "以后工作周报详细一点", key: "response-length", scope: .work))
        let summary = DailySummary(day: .now, content: "使用旧约定的合成回顾", sourceCaptureIDs: [record.id], todos: [], generationKind: .localFallback)
        try await store.upsertDailySummary(summary)
        let answer = ConversationMessage(role: .assistant, content: "旧约定回答", citations: [record.id])
        try await store.addMessage(answer)
        var state = await store.snapshot()
        guard let claim = state.memoryKnowledge.claims.first else { throw Failure(text: "没有准备好约定") }
        try expect(state.memoryKnowledge.dependencies.contains { $0.outputID == summary.id && $0.claimIDs.contains(claim.id) }, "派生结果缺少依赖关系")
        try await store.correctMemory(id: claim.id, content: "以后工作周报简洁一点", scope: .work)
        state = await store.snapshot()
        try expect(state.dailySummaries.isEmpty && !state.messages.contains { $0.id == answer.id }, "更正后旧派生正文仍在线")
        try expect(state.memoryKnowledge.claims.contains { $0.state == .retracted } && state.memoryKnowledge.claims.contains { $0.usable() && $0.content.contains("简洁") }, "更正没有保留旧版本与有效新版本")
        let live = state.memoryKnowledge.claims.first { $0.usable() }!
        try await store.retireMemory(id: live.id)
        state = await store.snapshot()
        let retrieval = MemoryRetrievalEngine().plan(question: "工作周报怎么写", state: state, fallback: state.captures)
        try expect(retrieval.preferences == nil && retrieval.evidence.isEmpty, "停用约定仍经原始记录或偏好上下文生效")
        _ = try await store.moveCapturesToRecentlyDeleted(ids: Set(state.captures.map(\.id)), reason: .noLongerNeeded, suppressSimilar: false)
        state = await store.snapshot()
        try expect(state.memoryKnowledge.claims.isEmpty && state.memoryKnowledge.entities.isEmpty, "彻底忘记后仍有派生记忆或人物内容")
    }
    static func canonicalReviews() async throws {
        let now = Date.now
        let owned = capture("[聊天·自己] 账单导出已定位，需要检查分页边界。\n[聊天·自己] 账单导出修复已验证通过。", day: now)
        let other = capture("[聊天·对方] 通知订阅修复已验证通过。", day: now)
        let state = RecallState(captures: [owned, other])
        let daily = try await DailySummaryGenerator().generate(day: now, from: state.captures)
        let files = MatterMemoryEngine().files(in: state)
        try expect(daily.consolidation.episodes.allSatisfy { $0.evidenceIDs == [owned.id] }, "每日总结使用了事实层拒绝的角色")
        try expect(daily.consolidation.projectStates.first?.currentState == files.first?.latest.detail, "每日总结与脉络的最新状态不一致")
        let knowledge = MemoryKnowledgeEngine().reconcile(state, force: true)
        var indexed = state; indexed.memoryKnowledge = knowledge
        let retrieval = MemoryRetrievalEngine().plan(question: "账单导出后来进展怎样", state: indexed, fallback: [])
        try expect(retrieval.evidence.contains { $0.ocrText.contains("已验证通过") }, "问一问未读取统一最新事实")
        try expect(retrieval.sourceIDs.values.allSatisfy { !$0.contains(other.id) }, "问一问把他人结果归给本人")
    }
    static func experiences() throws {
        let old = capture("[聊天·自己] 账单导出分页仍然失败。", day: .now.addingTimeInterval(-86_400 * 3))
        let method = capture("[聊天·自己] 账单导出已修改分页边界并补充测试。", day: .now.addingTimeInterval(-86_400 * 2))
        let fixed = capture("[聊天·自己] 账单导出分页修复已验证通过。", day: .now.addingTimeInterval(-86_400))
        var state = RecallState(captures: [old, method, fixed])
        var knowledge = MemoryKnowledgeEngine().reconcile(state, force: true)
        try expect(knowledge.claims.contains { $0.kind == .experience && $0.dependencies.count >= 3 }, "没有将问题与有结果的处理过程连成经验")
        state.captures = [old]
        knowledge = MemoryKnowledgeEngine().reconcile(state, force: true)
        try expect(!knowledge.claims.contains { $0.kind == .experience }, "缺少完成证据仍宣称形成可复用经验")
    }
    static func incrementalIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = try SQLiteIntelligenceIndex(databaseURL: root.appendingPathComponent("test.sqlite"))
        var record = capture("UniqueMemoryBefore")
        var state = RecallState(captures: [record])
        try index.replace(with: state)
        try index.synchronize(with: state)
        try expect(try index.searchCaptureIDs(matching: "UniqueMemoryBefore") == [record.id], "未变化行的索引失效")
        record.ocrText = "UniqueMemoryAfter"; state.captures = [record]
        try index.synchronize(with: state)
        try expect(try index.searchCaptureIDs(matching: "UniqueMemoryBefore").isEmpty, "增量修改残留旧全文索引")
        try expect(try index.searchCaptureIDs(matching: "UniqueMemoryAfter") == [record.id], "增量修改未写入新全文索引")
        state.captures = []; try index.synchronize(with: state)
        try expect(try index.searchCaptureIDs(matching: "UniqueMemoryAfter").isEmpty, "增量删除残留索引")
    }
}
