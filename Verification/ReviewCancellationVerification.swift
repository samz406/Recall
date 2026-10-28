import Foundation
import RecallKit

/// Hung HTTP, non-cooperative adapters and late results; no network or real user data.
enum ReviewCancellationVerification {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw ModelReviewVerification.Failure(message: message) }
    }
    actor Completion {
        var done = false, cancelled = false
        func finish(_ error: Error? = nil) { done = true; cancelled = error is CancellationError }
        func value() -> (Bool, Bool) { (done, cancelled) }
    }
    actor Gate {
        var continuation: CheckedContinuation<Void, Never>?
        var open = false
        func wait() async {
            if open { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { open = true; continuation?.resume(); continuation = nil }
    }
    actor PausedModel: LLMResponding {
        let purpose: LLMRequestPurpose
        let occurrence: Int
        let originalOnly: Bool
        let repair: Bool
        let networkCancelled: Bool
        let fallback = ModelReviewVerification.Model()
        var requests: [LLMRequest] = []
        var continuation: CheckedContinuation<Void, Never>?
        var blocked = false, returned = false
        init(_ purpose: LLMRequestPurpose, occurrence: Int = 1, originalOnly: Bool = false,
             repair: Bool = false, networkCancelled: Bool = false) {
            self.purpose = purpose; self.occurrence = occurrence; self.originalOnly = originalOnly
            self.repair = repair; self.networkCancelled = networkCancelled
        }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            requests.append(request)
            if networkCancelled { throw URLError(.cancelled) }
            let count = requests.filter { $0.purpose == purpose }.count
            let matching = !originalOnly || request.context[0].sourceAppName == "原始结构化事实核对"
            if repair, request.purpose == .captureUnderstanding, count == 1 {
                return LLMAnswer(content: "{broken", citedCaptureIDs: [])
            }
            if request.purpose == purpose, count >= occurrence, matching, !blocked {
                blocked = true
                // Intentionally ignore cancellation to exercise the late-answer boundary.
                await withCheckedContinuation { continuation = $0 }
                returned = true
            }
            return try await fallback.answer(to: request)
        }
        func release() { continuation?.resume(); continuation = nil }
        func isBlocked() -> Bool { blocked }
        func hasReturned() -> Bool { returned }
        func log() -> [LLMRequest] { requests }
    }
    static func until(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
    static func run() async throws {
        try immediateFeedback()
        try await realHTTPIsCancelled()
        try await alreadyCancelledMakesNoRequest()
        try await preparationCheckpointAndLateAnswer()
        try await preparationAuditStops()
        try await synthesisAndAuditsStop()
        try await networkCancellationIsNotFailure()
        try await cancellationDuringRepair()
        try await cancelledCommitGuards()
        try await scheduledCancellationSkipsOccurrence()
        print("PASS: 10 review-cancellation scenarios (HTTP abort, immediate status, late answers, checkpoints, repair and schedules)")
    }
    static func immediateFeedback() throws {
        var status = RecallTaskStatus(kind: "每日回顾", target: "合成日期", phase: "准备记录")
        try expect(status.requestCancellation() && status.isCancelling && status.isRunning && status.phase == "正在取消…", "点击取消没有立即改变界面状态")
        status.updateProgress(phase: "生成回顾", detail: "迟到的进度")
        try expect(status.phase == "正在取消…" && !status.requestCancellation(), "迟到进度覆盖了取消状态，或取消被重复执行")
        status.state = .cancelled
        try expect(!status.isRunning && !status.requestCancellation(), "取消后仍显示运行或允许再次取消")
    }
    static func realHTTPIsCancelled() async throws {
        for provider in [LLMProviderKind.openAICompatible, .anthropicCompatible] {
            CancellationURLProtocol.reset()
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CancellationURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let client = CompatibleLLM(configuration: LLMConfiguration(provider: provider, baseURLString: "https://example.invalid/v1",
                model: "synthetic", apiKey: "verification-placeholder"), apiKey: "verification-placeholder", session: session)
            let completion = Completion()
            let work = Task {
                do {
                    _ = try await client.answer(to: LLMRequest(question: "合成取消测试", context: [], purpose: .captureUnderstanding))
                    await completion.finish()
                } catch { await completion.finish(error) }
            }
            let started = await until { CancellationURLProtocol.counts().0 == 1 }
            work.cancel()
            let ended = await until { await completion.value().0 }
            let stopped = await until { CancellationURLProtocol.counts().1 == 1 }
            if !ended { session.invalidateAndCancel() }
            try expect(started && ended && stopped, "取消没有中断真实 HTTP 适配器，仍等待服务超时")
            await work.value
            let result = await completion.value()
            try expect(result.1 && CancellationURLProtocol.counts().0 == 1, "网络取消被当作连接错误或触发重复请求")
        }
    }
    static func alreadyCancelledMakesNoRequest() async throws {
        let gate = Gate(), completion = Completion(), model = ModelReviewVerification.Model()
        let work = Task {
            await gate.wait()
            do { _ = try await model.answerCancellably(to: LLMRequest(question: "取消前不应发送", context: [])); await completion.finish() }
            catch { await completion.finish(error) }
        }
        work.cancel(); await gate.release(); await work.value
        let log = await model.log(), result = await completion.value()
        try expect(log.isEmpty && result.1, "预先取消的任务仍发出了模型请求")
    }
    static func preparationCheckpointAndLateAnswer() async throws {
        let text = (0..<55).map { "[聊天·自己] Atlas 第 \($0) 个分页测试已完成，包含空值和边界验证。" }.joined(separator: "\n")
        let f = try await ModelReviewVerification.fixture(raw: true, text: text)
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let old = try await ReviewRecoveryVerification.baseline(f)
        let model = PausedModel(.captureUnderstanding, occurrence: 2), completion = Completion()
        let work = Task {
            do { _ = try await f.store.prepareModelReview(period: f.period, responder: model); await completion.finish() }
            catch { await completion.finish(error) }
        }
        let blocked = await until { await model.isBlocked() }
        work.cancel()
        let acknowledged = await until { await completion.value().0 }
        await model.release(); await work.value
        _ = await until { await model.hasReturned() }
        let state = await f.store.snapshot(), result = await completion.value()
        try expect(blocked && acknowledged && result.1, "取消仍在等待不响应取消的模型服务")
        try expect(state.understandingJobs[0].nextPage == 1 && state.understandingJobs[0].lease == nil
            && state.understandingJobs[0].state == .paused && state.understandingJobs[0].attempts == 0
            && state.understandingJobs[0].lastFailureCode == nil, "取消丢失分页、占用租约或被记为失败")
        try expect(state.captures[0].understanding == nil && state.dailySummaries.contains { $0.id == old.id && $0.content == old.content }, "迟到结果覆盖了旧理解或回顾")
        var settings = CaptureUnderstandingSettings(); settings.enabled = true
        try await f.store.updateCaptureUnderstandingSettings(settings)
        let background = try await f.store.claimCaptureUnderstanding()
        try expect(background == nil, "后台整理接走了用户刚取消的历史记录，擅自继续处理")
        let resumed = ModelReviewVerification.Model()
        _ = try await f.store.prepareModelReview(period: f.period, responder: resumed)
        let log = await resumed.log().filter { $0.purpose == .captureUnderstanding }
        try expect(log.count == 2, "取消后重试没有从未完成分页接续")
    }
    static func preparationAuditStops() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = PausedModel(.captureUnderstandingAudit), completion = Completion()
        let work = Task {
            do { _ = try await f.store.prepareModelReview(period: f.period, responder: model); await completion.finish() }
            catch { await completion.finish(error) }
        }
        let blocked = await until { await model.isBlocked() }
        work.cancel(); let ended = await until { await completion.value().0 }
        await model.release(); await work.value
        let log = await model.log(), state = await f.store.snapshot()
        try expect(blocked && ended && log.count == 2 && state.captures[0].understanding == nil,
            "核对期间取消仍保存了理解或启动后续请求")
    }
    static func synthesisAndAuditsStop() async throws {
        for (purpose, original) in [(LLMRequestPurpose.reviewSynthesis, false), (.reviewAudit, false), (.reviewAudit, true)] {
            let f = try await ModelReviewVerification.fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
            let old = try await ReviewRecoveryVerification.baseline(f), state = await f.store.snapshot()
            let model = PausedModel(purpose, originalOnly: original), completion = Completion()
            let work = Task {
                do {
                    let result = try await ModelReviewEngine().generate(in: state, period: f.period,
                        beforeCall: { try await f.store.validateModelReview(state, period: f.period) }, responder: model)
                    try await f.store.commitModelDailySummary(result.dailySummary(day: f.records[0].createdAt), expected: state, period: f.period)
                    await completion.finish()
                } catch { await completion.finish(error) }
            }
            let blocked = await until { await model.isBlocked() }, before = await model.log().count
            work.cancel(); let ended = await until { await completion.value().0 }
            await model.release(); await work.value
            let log = await model.log(), after = await f.store.snapshot(), result = await completion.value()
            try expect(blocked && ended && result.1 && log.count == before && after.dailySummaries.contains { $0.id == old.id },
                "综合或最终核对取消后仍重试、继续审核或保存")
        }
    }
    static func networkCancellationIsNotFailure() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = PausedModel(.captureUnderstanding, networkCancelled: true)
        do { _ = try await f.store.prepareModelReview(period: f.period, responder: model); throw ModelReviewVerification.Failure(message: "网络取消没有抛出取消") }
        catch is CancellationError { }
        let state = await f.store.snapshot(), log = await model.log()
        try expect(log.count == 1 && state.understandingJobs[0].state == .paused && state.understandingJobs[0].lastFailureCode == nil,
            "URLError.cancelled 被记为连接失败或自动重试")
    }
    static func cancellationDuringRepair() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = PausedModel(.captureUnderstanding, occurrence: 2, repair: true), completion = Completion()
        let work = Task {
            do { _ = try await f.store.prepareModelReview(period: f.period, responder: model); await completion.finish() }
            catch { await completion.finish(error) }
        }
        let blocked = await until { await model.isBlocked() }
        work.cancel(); let ended = await until { await completion.value().0 }
        await model.release(); await work.value
        let log = await model.log(), result = await completion.value()
        try expect(blocked && ended && result.1 && log.count == 2, "自动修复期间取消仍继续核对或重试")
    }
    static func cancelledCommitGuards() async throws {
        let f = try await ModelReviewVerification.fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let old = try await ReviewRecoveryVerification.baseline(f)
        let result = try await ModelReviewVerification.generate(f, model: ModelReviewVerification.Model())
        let snapshot = await f.store.snapshot()
        let report = result.dailySummary(day: f.records[0].createdAt)
        let weekly = result.weeklyReport(period: f.period, template: ReviewTemplate(kind: .personal), scope: ReviewScope(), in: snapshot)
        let topic = TopicModelReview(topicID: "synthetic-cancelled", result: result)
        for kind in 0..<3 {
            let gate = Gate(), completion = Completion()
            let work = Task {
                await gate.wait()
                do {
                    switch kind {
                    case 0: try await f.store.commitModelDailySummary(report, expected: snapshot, period: f.period)
                    case 1: _ = try await f.store.commitWeeklyReport(weekly)
                    default: try await f.store.commitTopicReview(topic)
                    }
                    await completion.finish()
                } catch { await completion.finish(error) }
            }
            work.cancel(); await gate.release(); await work.value
            let completed = await completion.value()
            try expect(completed.1, "保存入口没有拒绝已取消的任务")
        }
        let state = await f.store.snapshot()
        try expect(state.weeklyReports.isEmpty && state.topicReviews.isEmpty && state.dailySummaries.contains { $0.id == old.id },
            "取消后的保存入口覆盖了原报告")
    }
    static func scheduledCancellationSkipsOccurrence() async throws {
        let f = try await ModelReviewVerification.fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let now = Date.now, schedule = ReviewSchedule(template: ReviewTemplate(kind: .personal))
        try await f.store.saveReviewSchedule(schedule, now: now.addingTimeInterval(-8 * 86_400))
        let before = await f.store.snapshot().reviewSchedules[0]
        try expect(before.isDue(at: now), "合成周期计划没有到期")
        let gate = Gate()
        let work = Task { await gate.wait(); try await f.store.deferReviewSchedule(before, noEvidence: true, now: now) }
        work.cancel(); await gate.release(); try await work.value
        let after = await f.store.snapshot().reviewSchedules[0]
        try expect(after.isEnabled && !after.isDue(at: now) && after.failureCount == 0 && after.nextRunAt == before.nextTrigger(after: now),
            "取消当前计划后又立即自动生成，或停用了后续周期")
    }
}

private final class CancellationURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var started = 0
    nonisolated(unsafe) private static var stopped = 0
    static func reset() { lock.lock(); defer { lock.unlock() }; started = 0; stopped = 0 }
    static func counts() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (started, stopped) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.lock(); Self.started += 1; Self.lock.unlock() }
    override func stopLoading() { Self.lock.lock(); Self.stopped += 1; Self.lock.unlock() }
}
