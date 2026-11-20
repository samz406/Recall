import Foundation
import RecallKit

/// The same store entry point used by the app, with synthetic records and no network.
enum DirectDailyReviewVerification {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ModelReviewVerification.Failure(message: message) }
    }
    actor MetricsLog {
        var values: [DailyReviewMetrics] = []
        func add(_ value: DailyReviewMetrics) { values.append(value) }
        func all() -> [DailyReviewMetrics] { values }
    }
    actor Model: LLMResponding {
        let mode: String
        var requests: [LLMRequest] = []
        var active = 0, peak = 0, blocked = false
        var waiter: CheckedContinuation<Void, Never>?
        let hook: (@Sendable () async throws -> Void)?
        init(_ mode: String = "valid", hook: (@Sendable () async throws -> Void)? = nil) { self.mode = mode; self.hook = hook }
        func log() -> [LLMRequest] { requests }
        func maximumActive() -> Int { peak }
        func isBlocked() -> Bool { blocked }
        func release() { waiter?.resume(); waiter = nil }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            requests.append(request); let ordinal = requests.count
            active += 1; peak = max(peak, active)
            defer { active -= 1 }
            guard request.purpose == .reviewSynthesis, request.context.count == 1,
                  request.context[0].imageRelativePath == nil, request.recentMessages.isEmpty else {
                throw ModelReviewVerification.Failure(message: "每日回顾仍调用逐条理解/审核，或附带多余数据")
            }
            if ordinal == 1 { try await hook?() }
            if mode == "pause", !blocked {
                blocked = true
                // Deliberately ignore cancellation; a late answer must still be discarded.
                await withCheckedContinuation { waiter = $0 }
            } else { try await Task.sleep(for: .milliseconds(25)) }
            let docs = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
            let final = request.question.contains("生成最终回顾，")
            if mode == "fail-final", final { throw LLMResponseFailure(reason: .service) }
            if mode == "rate" { throw LLMResponseFailure(reason: .rateLimited) }
            if mode == "capacity", docs.count > 2 { throw LLMResponseFailure(reason: .contextLimit) }
            if mode == "bad-json" || (mode == "repair-json" && ordinal == 1) { return LLMAnswer(content: "{broken", citedCaptureIDs: []) }
            let selected = docs.last!, id = selected["id"] as! String
            let text = selected["text"] as! String
            let quote = String(((selected["quotes"] as? [String])?.last ?? text.components(separatedBy: "\n").last!).suffix(100))
            let badOwner = mode == "other-once" && ordinal == 1
            let action = mode == "action" || badOwner
            var item: [String: Any] = ["section": action ? "actions" : "progress", "title": action ? "补齐 Atlas 边界验证" : "Atlas 分页边界结果已记录",
                "detail": action ? "补齐边界用例后提交评审，保留本人明确的未完成承诺。" : "本期分页边界验证已记录，保留原始来源和最终状态。",
                "owner": action ? "user" : "unknown", "status": action ? "pending" : "completed",
                "explicitCommitment": action, "condition": NSNull(), "evidence": [["id": id, "quote": quote]]]
            if mode == "repair-proof", ordinal == 1 { item["evidence"] = [["id": id, "quote": "原文不存在的伪造句子"]] }
            let coverage = docs.map { doc in ["id": doc["id"]!, "disposition": (doc["id"] as! String) == id ? "used" : mode == "uncertain" ? "uncertain" : "background"] }
            let value: [String: Any] = ["overview": final ? "本期记录了 Atlas 分页边界验证的进展。" : "", "items": [item], "coverage": coverage]
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    static func run() async throws {
        try await normalDayIsOneCall()
        try await cachedUnderstandingIsOptional()
        try await exactDuplicatesKeepAllSources()
        try await explicitActionAndStableID()
        try await othersAndReferencesAreNotMyActions()
        try await knownCompletionCannotBecomeAction()
        try await targetedRepairs()
        try await ledgerProgressReachesTheReview()
        try await incompleteRegenerationUsesSameDayEvidence()
        try await ledgerSurvivesProviderCapacityFallback()
        try await boundedParallelBatchesAndFullTail()
        try await restartResumesBatches()
        try await capacityFallback()
        try await cancellationDiscardsLateAnswer()
        try await sourceAndPrivacyRaces()
        try await failuresKeepOldReview()
        try await failedScheduleRequiresExplicitRetry()
        try await sameDateHasOneActiveGeneration()
        try await checkpointsWithdrawWithSources()
        try await maintenanceAndMigration()
        print("PASS: direct daily reviews cover visible progress, omission repair, full group ledgers, one-call synthesis, restart, provenance and actions")
    }
    static func generate(_ f: ModelReviewVerification.Fixture, model: Model, store: FileMemoryStore? = nil,
                         limits: DailyReviewLimits = DailyReviewLimits(), metrics: MetricsLog? = nil,
                         policy: DailyReviewGenerationPolicy = .replaceExisting) async throws -> DirectDailyReviewOutcome {
        try await (store ?? f.store).generateDirectDailyReview(day: f.records[0].createdAt, period: f.period, responder: model,
            policy: policy, limits: limits, onMetrics: { await metrics?.add($0) })
    }
    static func normalDayIsOneCall() async throws {
        let f = try await ModelReviewVerification.fixture(count: 36, raw: true)
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Model(), log = MetricsLog()
        let output = try await generate(f, model: model, metrics: log)
        let requests = await model.log(), state = await f.store.snapshot(), metrics = await log.all()
        try expect(requests.count == 1 && output.metrics.modelCalls == 1 && output.metrics.sourceCount == 36,
            "普通每日回顾没有收敛到一次模型调用")
        try expect(state.understandingJobs.isEmpty && state.captures.allSatisfy { $0.understanding == nil }
            && state.dailyReviewCheckpoints.isEmpty, "每日回顾仍强制逐条理解或保存不必要检查点")
        try expect(Set(output.summary.sourceCaptureIDs) == Set(f.records.map(\.id)) && output.summary.generationKind == .cloud,
            "一次生成漏掉范围内来源或退回本地摘要")
        try expect(metrics.count == 1 && metrics[0].modelCalls == 1 && metrics[0].inputBytes > 0
            && metrics[0].totalMilliseconds >= metrics[0].modelMilliseconds, "调用数和耗时没有按实际请求记录")
    }
    static func cachedUnderstandingIsOptional() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true)
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        _ = try await f.store.prepareModelReview(period: f.period, responder: ModelReviewVerification.Model())
        let model = Model(), output = try await generate(f, model: model)
        let calls = await model.log()
        try expect(calls.count == 1 && output.metrics.reusedRecords == 1 && calls[0].context[0].ocrText.contains("understood"),
            "有效的已有理解没有复用，或又请求了一次模型理解")
    }
    static func exactDuplicatesKeepAllSources() async throws {
        let f = try await ModelReviewVerification.fixture(count: 6, raw: true,
            text: "[聊天·自己] Atlas 同一个分页结果已经完成，原始记录保持不变。")
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Model(), output = try await generate(f, model: model)
        let calls = await model.log()
        let docs = try JSONSerialization.jsonObject(with: Data(calls[0].context[0].ocrText.utf8)) as! [[String: Any]]
        try expect(docs.count == 1 && output.summary.sourceCaptureIDs.count == 6
            && output.summary.items[0].evidenceIDs.count == 6, "重复截图没有在调用前合并，或合并丢失来源")
    }
    static func explicitActionAndStableID() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true, text: "[聊天·自己] Atlas 的边界验证交给我，明早给评审。")
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let first = try await generate(f, model: Model("action")), second = try await generate(f, model: Model("action"))
        try expect(first.summary.todos.count == 1 && first.summary.todos[0].id == second.summary.todos[0].id,
            "明确承诺被关键词拦截，或重复生成丢失行动身份")
    }
    static func othersAndReferencesAreNotMyActions() async throws {
        for text in ["[聊天·对方] Atlas 的边界验证交给我，明早给评审。", "[聊天·自己] [内容·资料] Atlas 的边界验证交给我，明早给评审。"] {
            let f = try await ModelReviewVerification.fixture(raw: true, text: text)
            defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
            let model = Model("other-once"), output = try await generate(f, model: model)
            let calls = await model.log()
            try expect(output.summary.todos.isEmpty && calls.count == 2 && calls[1].question.contains("归属"),
                "对方或引用内容被生成为本人待办，或没有定向修正")
        }
    }
    static func knownCompletionCannotBecomeAction() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true)
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        _ = try await f.store.prepareModelReview(period: f.period, responder: ModelReviewVerification.Model())
        let old = try await ReviewRecoveryVerification.baseline(f), model = Model("action")
        do { _ = try await generate(f, model: model); throw ModelReviewVerification.Failure(message: "已核对完成状态被重新变成待办") }
        catch let error as ModelReviewError { guard case .validation(.actionState) = error else { throw error } }
        let state = await f.store.snapshot(), calls = await model.log()
        try expect(calls.count == 2 && state.dailySummaries.contains { $0.id == old.id }, "行动修正无界重试或覆盖旧回顾")
    }
    static func targetedRepairs() async throws {
        for mode in ["repair-json", "repair-proof"] {
            let f = try await ModelReviewVerification.fixture(raw: true)
            defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
            let model = Model(mode); _ = try await generate(f, model: model)
            let calls = await model.log()
            try expect(calls.count == 2 && calls[1].question.contains("本地校验发现"), "本地校验失败没有限次定向修正")
        }
    }
    private actor CompletenessModel: LLMResponding {
        enum Mode { case ledger, onlyAction, repair, providerCapacity }
        static let records = [
            (topic: "Nova 导出", quote: "Nova 导出已合并，批量写入的回归用例已经通过。", section: "progress", status: "completed"),
            (topic: "Cedar 验收", quote: "Cedar 验收在沙盒跑通，部署后的验证尚未进行。", section: "progress", status: "inProgress"),
            (topic: "Birch 对账", quote: "Birch 对账由我明早核对并发给评审。", section: "actions", status: "pending"),
            (topic: "Moss 回归", quote: "Moss 回归的通过依赖启用合成缓存的实验开关。", section: "insights", status: "unknown")
        ]
        let mode: Mode
        var requests: [LLMRequest] = []
        init(_ mode: Mode) { self.mode = mode }
        func log() -> [LLMRequest] { requests }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            requests.append(request)
            let docs = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
            let grouped = docs.allSatisfy { ($0["basis"] as? String) == "summary" }
            if mode == .providerCapacity, !grouped, docs.count > 2 { throw LLMResponseFailure(reason: .contextLimit) }
            let rows = Self.records.compactMap { record -> [String: Any]? in
                guard let document = docs.first(where: { doc in
                    ((doc["quotes"] as? [String]) ?? [doc["text"] as! String]).contains { $0.contains(record.quote) }
                }) else { return nil }
                return ["section": record.section, "title": record.topic + "状态已记录", "detail": record.quote,
                    "topic": record.topic, "kind": "matter", "owner": "user", "status": record.status,
                    "explicitCommitment": record.section == "actions", "condition": NSNull(),
                    "evidence": [["id": document["id"]!, "quote": record.quote]]]
            }
            let omit = mode == .onlyAction || (mode == .repair && requests.count == 1)
            let focus = rows.first { ($0["section"] as? String) == "actions" } ?? rows.first!
            var ledger = omit ? [] : rows
            if mode == .ledger {
                var invalid = rows[0]
                invalid["title"] = "无依据的合成进展"
                invalid["evidence"] = [["id": docs[0]["id"]!, "quote": "原始材料中不存在的文字"]]
                ledger.append(invalid)
            }
            let coverage = (omit ? Array(docs.dropLast()) : docs).map { ["id": $0["id"]!, "disposition": "used"] }
            let answer: [String: Any] = ["overview": "Nova 已合并，Cedar 完成沙盒验收。", "items": [focus], "ledger": ledger, "coverage": coverage]
            return LLMAnswer(content: try ReviewRecoveryVerification.json(answer), citedCaptureIDs: [])
        }
    }
    private static func completenessFixture(long: Bool = false) async throws -> ModelReviewVerification.Fixture {
        let fixture = try await ModelReviewVerification.fixture(count: CompletenessModel.records.count, raw: true)
        for (source, record) in zip(fixture.records, CompletenessModel.records) {
            let filler = long ? String(repeating: "用于容量验证的合成材料。", count: 100) + "\n" : ""
            try await fixture.store.correctCaptureText(source.id, text: filler + "[聊天·自己] " + record.quote)
        }
        return fixture
    }
    private static func ledgerProgressReachesTheReview() async throws {
        let fixture = try await completenessFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storage.rootURL) }
        let output = try await fixture.store.generateDirectDailyReview(day: fixture.records[0].createdAt,
            period: fixture.period, responder: CompletenessModel(.ledger))
        let state = await fixture.store.snapshot()
        let visible = DailyReviewPresentation.items(in: output.summary, state: state)
        try expect(output.metrics.modelCalls == 1 && visible.filter { $0.section == .progress }.map(\.knowledge?.topic) == ["Nova 导出", "Cedar 验收"],
            "仅有行动重点时，没有在一次请求内恢复已核对的两条主线进展")
        try expect(visible.count == 3 && output.summary.todos.count == 1 && output.summary.ledger.count == 4
            && output.summary.modelCoverage?.isPartial == false && output.summary.content.contains("部署后的验证尚未进行"),
            "整理进展时丢失验证限制、重复条目，或把事项清单的引用当成未覆盖")
    }
    private static func incompleteRegenerationUsesSameDayEvidence() async throws {
        let fixture = try await completenessFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storage.rootURL) }
        let day = fixture.records[0].createdAt
        var legacy = try await fixture.store.generateDirectDailyReview(day: day, period: fixture.period,
            responder: CompletenessModel(.onlyAction)).summary
        try expect(legacy.items.map(\.section) == [.actions] && legacy.modelOverview?.isEmpty == true
            && legacy.modelCoverage?.uncertainBlockCount == 3, "遗漏或未核验的材料被误判为背景，或概览写了正文没有的进展")
        let detailed = try await fixture.store.generateDirectDailyReview(day: day, period: fixture.period,
            responder: CompletenessModel(.ledger)).summary
        legacy.createdAt = detailed.createdAt.addingTimeInterval(1)
        legacy.versions = [DailyReviewVersion(summary: detailed)]
        try await fixture.store.upsertDailySummary(legacy)

        let incomplete = CompletenessModel(.onlyAction)
        do {
            _ = try await fixture.store.generateDirectDailyReview(day: day, period: fixture.period, responder: incomplete)
            throw ModelReviewVerification.Failure(message: "连续遗漏已核对的进展仍被发布")
        } catch let error as ModelReviewError {
            guard case .validation(.importantContentMissing) = error else { throw error }
        }
        let attempts = await incomplete.log(), state = await fixture.store.snapshot()
        try expect(attempts.count == 2 && attempts[1].question.contains("请重点核对材料 d1、d2")
            && state.dailySummaries == [legacy], "遗漏未定向修正一次，或失败后改动了已保存版本")
        let repaired = try await fixture.store.generateDirectDailyReview(day: day, period: fixture.period,
            responder: CompletenessModel(.repair))
        try expect(repaired.metrics.modelCalls == 2 && repaired.summary.items.filter { $0.section == .progress }.count == 2
            && repaired.summary.versions?.map(\.id) == [legacy.id, detailed.id], "修正成功后仍缺当天进展，或未保留两个历史版本")
    }
    private static func ledgerSurvivesProviderCapacityFallback() async throws {
        let fixture = try await completenessFixture(long: true)
        defer { try? FileManager.default.removeItem(at: fixture.storage.rootURL) }
        let model = CompletenessModel(.providerCapacity)
        let output = try await fixture.store.generateDirectDailyReview(day: fixture.records[0].createdAt, period: fixture.period, responder: model)
        let calls = await model.log()
        try expect(calls.count == 4 && output.summary.items.filter { $0.section == .progress }.count == 2
            && output.summary.ledger.first { $0.topic == "Moss 回归" }?.evidenceIDs == [fixture.records[3].id],
            "容量拆分丢失了分组清单的事项，或最终清单未恢复原始记录的引用")
    }
    static func largeFixture() async throws -> ModelReviewVerification.Fixture {
        let f = try await ModelReviewVerification.fixture(count: 4, raw: true)
        for (index, source) in f.records.enumerated() {
            let text = "[聊天·自己] Atlas 第 \(index) 组：" + String(repeating: "分页边界的合成记录正文。", count: 220) + "\n[聊天·自己] 第 \(index) 组文末尾部用例已经验收。"
            try await f.store.correctCaptureText(source.id, text: text)
        }
        return f
    }
    static func boundedParallelBatchesAndFullTail() async throws {
        let f = try await largeFixture()
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Model(), output = try await generate(f, model: model, limits: DailyReviewLimits(inputBytes: 18_000, concurrency: 2))
        let calls = await model.log(), peak = await model.maximumActive()
        let bodies = calls.map { $0.context[0].ocrText }.joined()
        try expect(peak == 2 && output.metrics.modelCalls == calls.count && calls.count > 1,
            "超量分组没有并发两组，或调用计数不准确")
        for i in 0..<4 { try expect(bodies.contains("第 \(i) 组文末尾部用例"), "长记录末尾被截掉") }
        try expect(Set(output.summary.sourceCaptureIDs) == Set(f.records.map(\.id)), "分组遗漏了原始来源")
    }
    static func restartResumesBatches() async throws {
        let f = try await largeFixture()
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let old = try await ReviewRecoveryVerification.baseline(f)
        do { _ = try await generate(f, model: Model("fail-final"), limits: DailyReviewLimits(inputBytes: 18_000)); throw ModelReviewVerification.Failure(message: "综合失败被当作成功") }
        catch is LLMResponseFailure { }
        let before = await f.store.snapshot()
        try expect(!before.dailyReviewCheckpoints.isEmpty && before.dailySummaries.contains { $0.id == old.id }, "分组未保存断点或先删除旧稿")
        let reopened = try verificationStore(storage: f.storage), model = Model()
        let output = try await generate(f, model: model, store: reopened, limits: DailyReviewLimits(inputBytes: 18_000))
        let calls = await model.log()
        try expect(output.metrics.cacheHits > 0 && calls.count == 1, "重启重试又重新请求已完成的分组")
        // Simulate an idle app with expired checkpoints still on disk, before maintenance.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var archive = try JSONSerialization.jsonObject(with: encoder.encode(before)) as! [String: Any]
        var checkpoints = archive["dailyReviewCheckpoints"] as! [[String: Any]]
        for i in checkpoints.indices { checkpoints[i]["createdAt"] = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-8 * 86_400)) }
        archive["dailyReviewCheckpoints"] = checkpoints
        try JSONSerialization.data(withJSONObject: archive).write(to: f.storage.stateURL)
        let expired = try verificationStore(storage: f.storage), fresh = Model()
        let regenerated = try await generate(f, model: fresh, store: expired, limits: DailyReviewLimits(inputBytes: 18_000))
        try expect(regenerated.metrics.cacheHits == 0 && regenerated.metrics.modelCalls > 1, "过期检查点仍被复用")
    }
    static func capacityFallback() async throws {
        let f = try await largeFixture()
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Model("capacity"), output = try await generate(f, model: model)
        try expect(output.metrics.modelCalls > 1 && output.summary.sourceCaptureIDs.count == 4,
            "服务端容量更小时没有拆分恢复或丢失来源")
    }
    static func cancellationDiscardsLateAnswer() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true)
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let old = try await ReviewRecoveryVerification.baseline(f), model = Model("pause"), completion = ReviewCancellationVerification.Completion()
        let work = Task {
            do { _ = try await generate(f, model: model); await completion.finish() }
            catch { await completion.finish(error) }
        }
        let blocked = await ReviewCancellationVerification.until { await model.isBlocked() }
        work.cancel()
        let ended = await ReviewCancellationVerification.until { await completion.value().0 }
        await model.release(); await work.value
        let state = await f.store.snapshot(), result = await completion.value(), calls = await model.log()
        try expect(blocked && ended && result.1 && calls.count == 1 && state.dailySummaries.contains { $0.id == old.id },
            "新链路取消失效、迟到结果保存或触发额外请求")
    }
    static func sourceAndPrivacyRaces() async throws {
        for mode in ["privacy", "edit", "delete"] {
            let f = try await ModelReviewVerification.fixture(raw: true)
            defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
            let model = Model(hook: {
                if mode == "privacy" { try await f.store.updatePrivacy(PrivacySettings(cloudUseEnabled: false)) }
                else if mode == "edit" { try await f.store.correctCaptureText(f.records[0].id, text: "[聊天·自己] 原文已更正，不采用旧稿。") }
                else { _ = try await f.store.deleteCapture(id: f.records[0].id) }
            })
            do { _ = try await generate(f, model: model); throw ModelReviewVerification.Failure(message: "来源或许可变化后仍保存旧回答") }
            catch let error as ModelReviewError { guard case .changed = error else { throw error } }
            let state = await f.store.snapshot(), calls = await model.log()
            try expect(state.dailySummaries.isEmpty && calls.count == 1, "失效回答被保存或继续发送材料")
        }
    }
    static func failuresKeepOldReview() async throws {
        for mode in ["bad-json", "rate"] {
            let f = try await ModelReviewVerification.fixture(raw: true)
            defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
            let old = try await ReviewRecoveryVerification.baseline(f), model = Model(mode), metrics = MetricsLog()
            do { _ = try await generate(f, model: model, metrics: metrics); throw ModelReviewVerification.Failure(message: "失败结果被保存") }
            catch is ModelReviewError { } catch is LLMResponseFailure { }
            let state = await f.store.snapshot(), calls = await model.log(), measured = await metrics.all()
            try expect(state.dailySummaries.contains { $0.id == old.id } && calls.count == (mode == "rate" ? 1 : 2)
                && measured.count == 1 && measured[0].modelCalls == calls.count, "失败覆盖旧稿、无界重试或丢失统计")
        }
    }
    static func failedScheduleRequiresExplicitRetry() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true)
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        try await f.store.updateDailySummarySettings(DailySummarySettings(isEnabled: true))
        let broken = Model("bad-json")
        do {
            _ = try await generate(f, model: broken, policy: .scheduled)
            throw ModelReviewVerification.Failure(message: "无效回顾被保存")
        } catch let error as ModelReviewError {
            guard case .validation = error else { throw error }
        }
        let failedCalls = await broken.log()
        try expect(failedCalls.count == 2, "格式修复不应超过一次")

        let reopened = try verificationStore(storage: f.storage, deferMaintenance: true)
        let retry = Model()
        do {
            _ = try await generate(f, model: retry, store: reopened, policy: .scheduled)
            throw ModelReviewVerification.Failure(message: "重启后自动重跑了失败日期")
        } catch DailyReviewSkipped.alreadyAttempted { }
        let retried = try await generate(f, model: retry, store: reopened, policy: .fillMissing)
        do {
            _ = try await generate(f, model: retry, store: reopened, policy: .fillMissing)
            throw ModelReviewVerification.Failure(message: "补生成覆盖了已保存回顾")
        } catch DailyReviewSkipped.alreadySaved { }
        let calls = await retry.log(), after = await reopened.snapshot()
        try expect(calls.count == 1 && after.dailySummaries == [retried.summary], "同一天重启、手动重试后存在重复请求或重复回顾")
        print("PASS: failed automatic daily review stays paused across reopen, and an explicit retry fills it once")
    }

    static func sameDateHasOneActiveGeneration() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true)
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let duplicate = Model()
        let first = Model(hook: {
            do {
                _ = try await generate(f, model: duplicate, policy: .fillMissing)
                throw ModelReviewVerification.Failure(message: "同一天同时启动了两次生成")
            } catch DailyReviewSkipped.inProgress { }
        })
        let saved = try await generate(f, model: first, policy: .fillMissing)
        let duplicateCalls = await duplicate.log(), after = await f.store.snapshot()
        try expect(duplicateCalls.isEmpty && after.dailySummaries == [saved.summary], "重复请求发送模型调用或写入了第二份回顾")
    }

    static func checkpointsWithdrawWithSources() async throws {
        let f = try await largeFixture()
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        do { _ = try await generate(f, model: Model("fail-final"), limits: DailyReviewLimits(inputBytes: 18_000)) }
        catch is LLMResponseFailure { }
        _ = try await f.store.deleteCapture(id: f.records[0].id)
        let afterDelete = await f.store.snapshot()
        let encoded = String(decoding: try JSONEncoder().encode(afterDelete.dailyReviewCheckpoints), as: UTF8.self)
        try expect(!encoded.contains(f.records[0].id.uuidString), "删除来源后仍留有该来源的回顾检查点")
        var configuration = afterDelete.llmConfiguration; configuration.model = "another-synthetic-model"
        try await f.store.updateLLMConfiguration(configuration)
        let afterConfig = await f.store.snapshot()
        try expect(afterConfig.dailyReviewCheckpoints.isEmpty, "更换模型后仍复用旧模型的检查点")
    }
    static func maintenanceAndMigration() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true)
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let before = await f.store.snapshot(), output = try await generate(f, model: Model())
        let pending = await f.store.snapshot(), dirty = await f.store.memoryIndexNeedsRebuild()
        try expect(pending.pendingDailyReviewMaintenance.contains(output.summary.id) && pending.episodes == before.episodes && dirty,
            "保存回顾仍同步运行全量归并，或未标记后台索引维护")
        try await f.store.organizeMemory()
        let completed = await f.store.snapshot()
        try expect(completed.pendingDailyReviewMaintenance.isEmpty && completed.dailySummaries.contains { $0.id == output.summary.id },
            "后台维护没有完成或删除了新回顾")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RecallState())) as! [String: Any]
        object.removeValue(forKey: "dailyReviewCheckpoints"); object.removeValue(forKey: "pendingDailyReviewMaintenance")
        object.removeValue(forKey: "dailyReviewAttemptedDays")
        let restored = try JSONDecoder().decode(RecallState.self, from: JSONSerialization.data(withJSONObject: object))
        try expect(restored.dailyReviewCheckpoints.isEmpty && restored.pendingDailyReviewMaintenance.isEmpty
            && restored.dailyReviewAttemptedDays.isEmpty, "旧数据无法兼容新链路")
    }
}

