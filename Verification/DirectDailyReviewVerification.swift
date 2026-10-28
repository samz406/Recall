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
        try await boundedParallelBatchesAndFullTail()
        try await restartResumesBatches()
        try await capacityFallback()
        try await cancellationDiscardsLateAnswer()
        try await sourceAndPrivacyRaces()
        try await failuresKeepOldReview()
        try await checkpointsWithdrawWithSources()
        try await maintenanceAndMigration()
        print("PASS: 15 direct-daily-review scenarios (one-call normal path, bounded concurrency, reuse, restart, provenance, actions, cancellation and metrics)")
    }
    static func generate(_ f: ModelReviewVerification.Fixture, model: Model, store: FileMemoryStore? = nil,
                         limits: DailyReviewLimits = DailyReviewLimits(), metrics: MetricsLog? = nil) async throws -> DirectDailyReviewOutcome {
        try await (store ?? f.store).generateDirectDailyReview(day: f.records[0].createdAt, period: f.period, responder: model,
            limits: limits, onMetrics: { await metrics?.add($0) })
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
        let model = Model(), output = try await generate(f, model: model, limits: DailyReviewLimits(inputBytes: 18_000))
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
        let reopened = try FileMemoryStore(storage: f.storage), model = Model()
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
        let expired = try FileMemoryStore(storage: f.storage), fresh = Model()
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
        let restored = try JSONDecoder().decode(RecallState.self, from: JSONSerialization.data(withJSONObject: object))
        try expect(restored.dailyReviewCheckpoints.isEmpty && restored.pendingDailyReviewMaintenance.isEmpty, "旧数据无法兼容新链路")
    }
}
