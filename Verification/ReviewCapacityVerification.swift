import Foundation
import RecallKit

/// Capacity faults are fabricated; these exercise recovery, not production model quality.
enum ReviewCapacityVerification {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ModelReviewVerification.Failure(message: message) }
    }
    static func text(_ count: Int) -> String {
        (0..<count).map { "[聊天·自己] Atlas 第 \($0) 组分页边界验证已经完成，原始结果单独留档。" }.joined(separator: "\n")
    }
    actor Model: LLMResponding {
        let purpose: LLMRequestPurpose
        let maximum: Int
        let reason: LLMResponseFailure.Reason
        let needsLargeBudget: Bool
        let transport: Bool
        let fallback = ModelReviewVerification.Model()
        var requests: [LLMRequest] = []
        var audited: [String] = []
        var hook: (@Sendable () async throws -> Void)?
        init(_ purpose: LLMRequestPurpose = .captureUnderstanding, maximum: Int = 6,
             reason: LLMResponseFailure.Reason = .truncated, needsLargeBudget: Bool = false,
             transport: Bool = false, hook: (@Sendable () async throws -> Void)? = nil) {
            self.purpose = purpose; self.maximum = maximum; self.reason = reason
            self.needsLargeBudget = needsLargeBudget; self.transport = transport; self.hook = hook
        }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            requests.append(request)
            let blocks = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
            let primary = blocks.filter { $0["contextOnly"] as? Bool != true }
            if request.purpose == purpose {
                try await hook?()
                if transport { throw URLError(.timedOut) }
                if primary.count > maximum || (needsLargeBudget && (request.outputTokenLimit ?? 0) < 16_000) {
                    throw LLMResponseFailure(reason: reason, outputLimit: request.outputTokenLimit)
                }
            }
            let answer = try await fallback.answer(to: request)
            if request.purpose == .captureUnderstandingAudit { audited += primary.compactMap { $0["id"] as? String } }
            return answer
        }
        func log() -> [LLMRequest] { requests }
        func checked() -> [String] { audited }
    }
    static func run() async throws {
        try await draftCapacity()
        try await auditCapacity()
        try await contextCapacity()
        try await backgroundRecovery()
        try await restartPreservesPartitionAndCheckpoint()
        try await minimalPageBudget()
        try await minimalFailureIsBounded()
        try await unrelatedFailuresNeverSplit()
        try await privacyBeforeSubdivision()
        try await cancellationDuringSmallerPage()
        try await sourceChangeResetsPartition()
        try migrationAndPartitionValidity()
        print("PASS: 12 review-capacity scenarios (draft/audit/context subdivision, full coverage, restart, bounded budget, privacy and cancellation)")
    }
    static func verifyRecovery(_ purpose: LLMRequestPurpose, reason: LLMResponseFailure.Reason = .truncated) async throws {
        let f = try await ModelReviewVerification.fixture(raw: true, text: text(25))
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let old = try await ReviewRecoveryVerification.baseline(f)
        let model = Model(purpose, maximum: 6, reason: reason), progress = ReviewRecoveryVerification.ProgressLog()
        let state = try await f.store.prepareModelReview(period: f.period, responder: model,
            onProgress: { await progress.add($0) })
        let understanding = state.captures[0].understanding!
        let allIDs = Set(CaptureUnderstandingEngine.blocks(for: f.records[0]).map(\.id))
        let checked = await model.checked(), log = await model.log(), phases = await progress.log()
        try expect(understanding.coveredBlockCount == 25 && understanding.uncertainBlockCount == 0
            && understanding.facts.count == 25 && Set(checked) == allIDs && checked.count == 25,
            "拆分遗漏尾部、重复保存事实，或将失败草稿算作已核对")
        try expect(understanding.facts.flatMap(\.evidence).allSatisfy { allIDs.contains($0.blockID) && f.records[0].ocrText.contains($0.quote) },
            "拆分改变原文引用或来源 ID")
        try expect(state.dailySummaries.contains { $0.id == old.id && $0.content == old.content }
            && state.captures[0].ocrText == f.records[0].ocrText, "拆分期间改写了原回顾或原文")
        try expect(state.understandingJobs[0].pageBlockCounts == [6, 6, 6, 6, 1]
            && phases.contains { $0.detail.contains("已拆成更小段") }, "拆分方案或进度反馈没有保存")
        let before = log.count
        _ = try await f.store.prepareModelReview(period: f.period, responder: model)
        let reusedCount = await model.log().count
        try expect(reusedCount == before, "重试成功后没有复用完整理解结果")
        if reason == .contextLimit {
            let oversized = try log.filter { $0.purpose == purpose }.filter { request in
                let blocks = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
                return blocks.filter { $0["contextOnly"] as? Bool != true }.count > 6
            }
            try expect(oversized.allSatisfy { $0.outputTokenLimit == 6_000 }, "上下文超限仍反复增加输出预算")
        }
        let result = try await ModelReviewEngine().generate(in: state, period: f.period, responder: model)
        try await f.store.commitModelDailySummary(result.dailySummary(day: f.records[0].createdAt), expected: state, period: f.period)
        let saved = await f.store.snapshot()
        try expect(saved.dailySummaries.contains { $0.generationKind == .cloud && $0.content != old.content }, "准备恢复后未能完成正式模型回顾")
    }
    static func draftCapacity() async throws { try await verifyRecovery(.captureUnderstanding) }
    static func auditCapacity() async throws { try await verifyRecovery(.captureUnderstandingAudit, reason: .reasoningOnly) }
    static func contextCapacity() async throws { try await verifyRecovery(.captureUnderstanding, reason: .contextLimit) }

    static func backgroundRecovery() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true, text: text(12))
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        var settings = CaptureUnderstandingSettings(); settings.enabled = true
        try await f.store.updateCaptureUnderstandingSettings(settings)
        _ = try await f.store.enqueueCaptureUnderstanding(captureID: f.records[0].id)
        let model = Model(maximum: 3)
        for _ in 0..<12 {
            if await f.store.snapshot().captures[0].understanding != nil { break }
            _ = try await step(f, model: model, forReview: false)
        }
        let state = await f.store.snapshot(), checked = await model.checked()
        try expect(state.captures[0].understanding?.coveredBlockCount == 12 && checked.count == 12
            && state.understandingJobs[0].pageBlockCounts == [3, 3, 3, 3], "后台整理没有使用同一拆分恢复链路")
    }

    static func step(_ f: ModelReviewVerification.Fixture, store: FileMemoryStore? = nil,
                     model: any LLMResponding, forReview: Bool = true) async throws -> UnderstandingPageOutcome {
        let store = store ?? f.store, snapshot = await store.snapshot()
        guard let job = try await store.claimCaptureUnderstanding(captureID: f.records[0].id, forReview: forReview) else {
            throw ModelReviewVerification.Failure(message: "分页任务未能领取")
        }
        return try await store.processCaptureUnderstandingPage(job, responder: model,
            configuration: snapshot.llmConfiguration, privacy: snapshot.privacy, forReview: forReview)
    }
    static func restartPreservesPartitionAndCheckpoint() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true, text: text(52))
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        _ = try await f.store.enqueueCaptureUnderstanding(captureID: f.records[0].id, forReview: true)
        _ = try await step(f, model: ModelReviewVerification.Model())
        let split = try await step(f, model: Model(maximum: 12))
        try expect(split == .subdivided, "第二段超限没有自动拆分")
        _ = try await step(f, model: ModelReviewVerification.Model())
        let middle = await f.store.snapshot()
        try expect(middle.understandingJobs[0].nextPage == 2 && middle.understandingJobs[0].coveredBlocks == 36
            && middle.understandingJobs[0].pageBlockCounts == [24, 12, 12, 4], "拆分后前一检查点被重置")
        let reopened = try FileMemoryStore(storage: f.storage)
        try await reopened.recoverCaptureUnderstandingJobs()
        var settings = CaptureUnderstandingSettings(); settings.enabled = true
        try await reopened.updateCaptureUnderstandingSettings(settings)
        let background = try await reopened.claimCaptureUnderstanding()
        try expect(background == nil, "重启后后台接走了专属回顾分页")
        let model = ModelReviewVerification.Model()
        let finished = try await reopened.prepareModelReview(period: f.period, responder: model)
        let calls = await model.log().filter { $0.purpose == .captureUnderstanding }
        let first = try JSONSerialization.jsonObject(with: Data(calls[0].context[0].ocrText.utf8)) as! [[String: Any]]
        let firstID = first.first { $0["contextOnly"] as? Bool != true }?["id"] as? String ?? ""
        try expect(calls.count == 2 && firstID.contains(":36:")
            && finished.captures[0].understanding?.coveredBlockCount == 52, "重启没有按已保存的拆分边界继续")
    }
    static func minimalPageBudget() async throws {
        for purpose in [LLMRequestPurpose.captureUnderstanding, .captureUnderstandingAudit] {
            let f = try await ModelReviewVerification.fixture(raw: true)
            defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
            let model = Model(purpose, maximum: 1, needsLargeBudget: true)
            _ = try await f.store.prepareModelReview(period: f.period, responder: model)
            let calls = await model.log().filter { $0.purpose == purpose }
            try expect(calls.map(\.outputTokenLimit) == [6_000, 8_000, 16_000], "最小段仍被硬限制在 8000，或预算无界增长")
        }
    }
    static func minimalFailureIsBounded() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true)
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let old = try await ReviewRecoveryVerification.baseline(f), model = Model(maximum: 0)
        do { _ = try await f.store.prepareModelReview(period: f.period, responder: model); throw ModelReviewVerification.Failure(message: "最小段截断被当作成功") }
        catch let error as ReviewPreparationFailure { try expect(error.code == "understanding.outputCapacity", "最终容量不足提示没有区分具体原因") }
        let log = await model.log(), state = await f.store.snapshot()
        try expect(log.count == 3 && state.understandingJobs[0].pageBlockCounts == [1]
            && state.understandingJobs[0].nextPage == 0 && state.captures[0].understanding == nil
            && state.dailySummaries.contains { $0.id == old.id }, "最小段无限重试、跳过记录或损坏原回顾")
    }
    static func unrelatedFailuresNeverSplit() async throws {
        for (reason, transport) in [(LLMResponseFailure.Reason.authentication, false), (.rateLimited, false), (.service, false), (.service, true)] {
            let f = try await ModelReviewVerification.fixture(raw: true, text: text(12))
            defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
            let model = Model(maximum: 0, reason: reason, transport: transport)
            do { _ = try await f.store.prepareModelReview(period: f.period, responder: model); throw ModelReviewVerification.Failure(message: "服务失败却继续生成") }
            catch is ReviewPreparationFailure { }
            let log = await model.log(), state = await f.store.snapshot()
            try expect(log.count == 1 && state.understandingJobs[0].pageBlockCounts == [12], "认证、限流或网络失败被拆分重试")
        }
    }
    static func privacyBeforeSubdivision() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true, text: text(12))
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Model(maximum: 0, reason: .contextLimit, hook: {
            try await f.store.updatePrivacy(PrivacySettings(cloudUseEnabled: false))
        })
        do { _ = try await f.store.prepareModelReview(period: f.period, responder: model); throw ModelReviewVerification.Failure(message: "关闭许可后仍继续拆分") }
        catch let error as ModelReviewError { guard case .changed = error else { throw error } }
        let calls = await model.log(), state = await f.store.snapshot()
        try expect(calls.count == 1 && state.captures[0].understanding == nil, "拆分恢复绕过了云端许可")
    }
    static func cancellationDuringSmallerPage() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true, text: text(12))
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        _ = try await f.store.enqueueCaptureUnderstanding(captureID: f.records[0].id, forReview: true)
        _ = try await step(f, model: Model(maximum: 6))
        let model = ReviewCancellationVerification.PausedModel(.captureUnderstanding), completion = ReviewCancellationVerification.Completion()
        let work = Task {
            do { _ = try await f.store.prepareModelReview(period: f.period, responder: model); await completion.finish() }
            catch { await completion.finish(error) }
        }
        let blocked = await ReviewCancellationVerification.until { await model.isBlocked() }
        work.cancel()
        let ended = await ReviewCancellationVerification.until { await completion.value().0 }
        await model.release(); await work.value
        let state = await f.store.snapshot(), result = await completion.value(), calls = await model.log()
        try expect(blocked && ended && result.1 && calls.count == 1 && state.understandingJobs[0].state == .paused
            && state.understandingJobs[0].pageBlockCounts == [6, 6] && state.understandingJobs[0].nextPage == 0,
            "拆分后的任务取消失效或拆分进度丢失")
    }
    static func sourceChangeResetsPartition() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true, text: text(12))
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        _ = try await f.store.enqueueCaptureUnderstanding(captureID: f.records[0].id, forReview: true)
        _ = try await step(f, model: Model(maximum: 6))
        try await f.store.correctCaptureText(f.records[0].id, text: text(1))
        let state = try await f.store.prepareModelReview(period: f.period, responder: ModelReviewVerification.Model())
        try expect(state.captures[0].understanding?.coveredBlockCount == 1
            && state.understandingJobs[0].pageBlockCounts == [1], "更正原文后沿用了旧拆分方案或旧事实")
    }
    static func migrationAndPartitionValidity() throws {
        var job = CaptureUnderstandingJob(captureID: UUID())
        job.nextPage = 1; job.pageCount = 3
        let encoded = try JSONEncoder().encode(job)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "pageBlockCounts")
        let old = try JSONDecoder().decode(CaptureUnderstandingJob.self, from: JSONSerialization.data(withJSONObject: object))
        try expect(old.nextPage == 1 && old.pageBlockCounts == nil, "旧任务迁移丢失进度")
        let source = CaptureRecord(eventTemplate: .workCheckpoint, contentHash: "synthetic-partition", ocrText: text(25))
        var state = RecallState(); state.captures = [source]
        let pages = CaptureUnderstandingEngine.pages(for: source.id, in: state, blockCounts: [6, 6, 12, 1])
        let primary = pages.flatMap { $0.blocks.filter { !$0.contextOnly }.map(\.id) }
        try expect(primary == CaptureUnderstandingEngine.blocks(for: source).map(\.id)
            && pages[1].blocks.filter(\.contextOnly).count == 2, "拆分未覆盖全文或没有保留相邻上下文")
        try expect(CaptureUnderstandingEngine.pages(for: source.id, in: state, blockCounts: [6, 6]).isEmpty
            && CaptureUnderstandingEngine.pages(for: source.id, in: state, blockCounts: [25]).isEmpty,
            "损坏的拆分方案静默丢弃原文")
    }
}
