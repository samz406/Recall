import Foundation
import RecallKit

extension RecallLayoutPreviews {
    private enum DailyGenerationFailure: Error { case failed(String) }

    /// Exercise the app's real queue and store entry points, without a network service or credentials.
    private actor DailyGenerationModel: LLMResponding {
        var calls = 0
        let pauseFirst: Bool
        var waiting = false
        var waiter: CheckedContinuation<Void, Never>?
        init(pauseFirst: Bool = false) { self.pauseFirst = pauseFirst }
        func count() -> Int { calls }
        func isWaiting() -> Bool { waiting }
        func release() { waiting = false; waiter?.resume(); waiter = nil }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            calls += 1
            guard request.purpose == .reviewSynthesis, let context = request.context.first,
                  let docs = try JSONSerialization.jsonObject(with: Data(context.ocrText.utf8)) as? [[String: Any]],
                  let first = docs.first, let id = first["id"] as? String, let text = first["text"] as? String else {
                throw DailyGenerationFailure.failed("每日回顾请求未使用所选日期的脱敏文本")
            }
            if pauseFirst, calls == 1 {
                waiting = true
                await withCheckedContinuation { waiter = $0 }
            }
            let quote = (first["quotes"] as? [String])?.first ?? text.components(separatedBy: "\n").last!
            let item: [String: Any] = ["section": "progress", "title": "Atlas 合成分页验证完成",
                "detail": "Atlas 合成分页验证结果已记录，原始来源保留。", "owner": "unknown", "status": "completed",
                "explicitCommitment": false, "condition": NSNull(), "evidence": [["id": id, "quote": quote]]]
            let coverage = docs.map { ["id": $0["id"]!, "disposition": ($0["id"] as? String) == id ? "used" : "background"] }
            let value: [String: Any] = ["overview": "Atlas 合成分页验证结果已记录。", "items": [item], "coverage": coverage]
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), citedCaptureIDs: [])
        }
    }

    @MainActor private static func dailyGenerationFixture(savedYesterday: Bool = false,
                                                          responder: DailyGenerationModel) throws -> RecallAppModel {
        let calendar = Calendar.current, today = calendar.startOfDay(for: .now)
        var state = RecallState()
        state.privacy.cloudUseEnabled = true
        state.llmConfiguration = LLMConfiguration(provider: .openAICompatible, baseURLString: "https://synthetic.invalid/v1", model: "synthetic")
        state.llmConfiguration.credentialReference = UUID().uuidString
        state.dailySummarySettings = DailySummarySettings(isEnabled: true, hour: 0, minute: 0)
        for offset in 1...4 {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            state.captures.append(CaptureRecord(eventTemplate: .manualMoment, createdAt: day.addingTimeInterval(43_200),
                sourceAppName: "Synthetic Notes", contentHash: "synthetic-day-\(offset)",
                ocrText: "Atlas 合成分页验证已经完成，这是第 \(offset) 天的合成记录，原始来源保留。", textOrigin: .userInput))
        }
        if savedYesterday {
            let record = state.captures[0]
            state.dailySummaries = [DailySummary(day: record.createdAt, content: "合成的已保存回顾", sourceCaptureIDs: [record.id], todos: [], generationKind: .cloud)]
        }
        return try RecallAppModel(previewState: state, dailyReviewResponder: responder)
    }
    @MainActor private static func waitForDailyGeneration(_ model: RecallAppModel, paused: DailyGenerationModel? = nil) async throws {
        for _ in 0..<600 {
            if let paused {
                if await paused.isWaiting() { return }
            } else if !model.isGeneratingDailySummary { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw DailyGenerationFailure.failed("每日回顾队列未在合成验证时限内结束：\(model.tasks.first?.phase ?? "无任务")")
    }
    @MainActor static func verifyDailyReviewGeneration() async throws {
        try await verifySingleDayIsolation()
        try await verifyStaleDailyQueue()
        try await verifyExplicitDailyBatch()
        try await verifyDailyBatchCancellation()
        print("PASS: native daily generation saved-date skip, manual isolation, same-date deduplication, date-scoped status, stale-queue revalidation, explicit batch and cancellation")
    }
    @MainActor private static func verifySingleDayIsolation() async throws {
        let responder = DailyGenerationModel(pauseFirst: true)
        let model = try dailyGenerationFixture(savedYesterday: true, responder: responder)
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        let records = model.state.captures, old = model.state.dailySummaries[0]
        model.generateScheduledDailyReview(on: old.day)
        guard model.tasks.isEmpty else { throw DailyGenerationFailure.failed("自动任务重新生成了已有回顾") }
        model.generateScheduledDailyReview(on: records[2].createdAt)
        try await waitForDailyGeneration(model, paused: responder)
        model.generateScheduledDailyReview(on: records[1].createdAt)
        // Repeated clicks on an active date must not enqueue a second regeneration of that date.
        model.generateDailyReview(on: records[2].createdAt)
        model.generateDailyReview(on: records[3].createdAt)
        guard model.dailyReviewTask(on: records[2].createdAt)?.isRunning == true,
              model.dailyReviewTask(on: records[1].createdAt) == nil else {
            throw DailyGenerationFailure.failed("其他日期页面显示了当前生成任务")
        }
        await responder.release()
        try await waitForDailyGeneration(model)
        let count = await responder.count()
        guard count == 2, model.state.dailySummaries.count == 3,
              model.state.dailySummaries.contains(where: { $0.id == old.id }),
              !model.state.dailySummaries.contains(where: { Calendar.current.isDate($0.day, inSameDayAs: records[1].createdAt) }),
              model.tasks.allSatisfy({ $0.state == .succeeded || $0.state == .partial }) else {
            throw DailyGenerationFailure.failed("单日操作继续了其他日期的自动补齐，或重复生成/覆盖已有日期：\(model.tasks.map(\.phase))")
        }
        model.generateMissedDailySummaryIfNeeded()
        guard !model.isGeneratingDailySummary else { throw DailyGenerationFailure.failed("手动完成后刷新立即重启自动补齐") }
    }
    @MainActor private static func verifyStaleDailyQueue() async throws {
        let responder = DailyGenerationModel(pauseFirst: true), external = DailyGenerationModel()
        let model = try dailyGenerationFixture(responder: responder)
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        let records = model.state.captures
        model.generateScheduledDailyReview(on: records[2].createdAt)
        try await waitForDailyGeneration(model, paused: responder)
        model.generateScheduledDailyReview(on: records[1].createdAt)
        // Another legitimate generation saves a queued date before this queue reaches it.
        let calendar = Calendar.current, day = calendar.startOfDay(for: records[1].createdAt)
        let saved = try await model.store.generateDirectDailyReview(day: day,
            period: ReviewPeriod(start: day, end: calendar.date(byAdding: .day, value: 1, to: day)!), responder: external).summary
        await responder.release()
        try await waitForDailyGeneration(model)
        let count = await responder.count()
        guard count == 1, model.tasks.count == 1, model.state.dailySummaries.contains(where: { $0.id == saved.id }) else {
            throw DailyGenerationFailure.failed("队列执行前没有复查日期，已保存回顾被再次生成")
        }
    }
    @MainActor private static func verifyExplicitDailyBatch() async throws {
        let responder = DailyGenerationModel(), model = try dailyGenerationFixture(responder: responder)
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        let days = Array(model.state.captures.suffix(2).map(\.createdAt))
        model.backfillDailyReviews(days + days)
        try await waitForDailyGeneration(model)
        let count = await responder.count()
        guard count == 2, model.state.dailySummaries.count == 2,
              model.tasks.allSatisfy({ $0.state == .succeeded || $0.state == .partial }) else {
            throw DailyGenerationFailure.failed("明确选择多天后没有完整处理所选日期，或产生重复请求")
        }
    }
    @MainActor private static func verifyDailyBatchCancellation() async throws {
        let responder = DailyGenerationModel(pauseFirst: true), model = try dailyGenerationFixture(responder: responder)
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        let days = Array(model.state.captures.suffix(2).map(\.createdAt))
        model.backfillDailyReviews(days)
        try await waitForDailyGeneration(model, paused: responder)
        model.cancelDailyReview()
        await responder.release()
        try await waitForDailyGeneration(model)
        let cancelledCount = await responder.count()
        guard cancelledCount == 1, model.state.dailySummaries.isEmpty, model.tasks.count == 1,
              model.tasks.first?.state == .cancelled else { throw DailyGenerationFailure.failed("取消后继续生成批次中的其他日期") }
        model.generateDailyReview(on: days[0])
        try await waitForDailyGeneration(model)
        guard model.state.dailySummaries.count == 1 else { throw DailyGenerationFailure.failed("取消后无法手动重试") }
    }
}
