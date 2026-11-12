import Foundation
import RecallKit

extension RecallLayoutPreviews {
    private struct PeriodGenerationFailure: LocalizedError { let errorDescription: String? }
    private actor PeriodGenerationModel: LLMResponding {
        let omit: Bool
        var calls = 0
        init(omit: Bool = false) { self.omit = omit }
        func count() -> Int { calls }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            calls += 1
            guard request.purpose == .reviewSynthesis, let body = request.context.first?.ocrText,
                  let rows = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]], rows.count == 8 else {
                throw PeriodGenerationFailure(errorDescription: "周期回顾没有把八个工作事项完整交给模型")
            }
            let selected = omit ? Array(rows.prefix(5)) : rows
            let items = selected.map { row -> [String: Any] in
                ["section": "progress", "title": (row["topic"] as! String) + "验证已完成",
                 "detail": "合成验证的边界条件已核对并记录，生产发布尚待确认。",
                 "evidence": [["id": row["id"]!, "quote": row["title"]!]]]
            }
            // A dishonest used receipt without its evidence must not bypass completeness checks.
            let coverage = rows.map { ["id": $0["id"]!, "disposition": "used", "category": "work"] }
            let value: [String: Any] = ["overview": "八项合成工作均有验证进展，发布仍待确认。", "items": items, "coverage": coverage]
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    @MainActor static func verifyPeriodReviewGeneration() async throws {
        let calendar = Calendar.current, today = calendar.startOfDay(for: .now)
        var state = RecallState()
        state.privacy.cloudUseEnabled = true
        state.llmConfiguration = LLMConfiguration(provider: .openAICompatible, baseURLString: "https://synthetic.invalid/v1", model: "synthetic")
        for index in 0..<8 {
            let day = calendar.date(byAdding: .day, value: -(index % 5 + 1), to: today)!
            let title = "Atlas \(index + 1)号交付"
            let capture = CaptureRecord(eventTemplate: .workCheckpoint, createdAt: day.addingTimeInterval(36_000),
                contentHash: UUID().uuidString, ocrText: title + "已经验证，生产发布尚待确认。")
            state.captures.append(capture)
            let item = DailySummaryItem(section: .progress, title: title + "完成验证", detail: capture.ocrText,
                evidenceIDs: [capture.id], knowledge: DailyItemKnowledge(topic: title, kind: .matter, status: "completed",
                    ownedByUser: true, quotes: [capture.ocrText], category: index == 7 ? nil : "work"))
            if let existing = state.dailySummaries.firstIndex(where: { $0.day == day }) {
                state.dailySummaries[existing].items.append(item); state.dailySummaries[existing].sourceCaptureIDs.append(capture.id)
            } else {
                var summary = DailySummary(day: day, content: "合成每日回顾", sourceCaptureIDs: [capture.id], todos: [], generationKind: .cloud, items: [item])
                summary.items = [item]; state.dailySummaries.append(summary)
            }
        }
        let period = ReviewPeriod(start: calendar.date(byAdding: .day, value: -7, to: today)!, end: today)
        var previous: WeeklyReport?
        for omit in [false, true] {
            let responder = PeriodGenerationModel(omit: omit)
            var input = state
            if let previous { input.weeklyReports = [previous] }
            let model = try RecallAppModel(previewState: input, dailyReviewResponder: responder)
            defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
            let originalCaptures = model.state.captures, originalDaily = model.state.dailySummaries
            model.generateWeeklyReview(period: period, template: ReviewTemplate(kind: .work), scope: ReviewScope())
            for _ in 0..<600 {
                if !model.isGeneratingWeeklyReview { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard !model.isGeneratingWeeklyReview, model.state.captures == originalCaptures, model.state.dailySummaries == originalDaily else {
                throw PeriodGenerationFailure(errorDescription: "周期生成没有结束，或改写了已有每日回顾/原始记录")
            }
            if omit {
                guard await responder.count() == 2, model.state.weeklyReports == [previous!],
                      model.tasks.contains(where: { $0.state == .failed }) else {
                    throw PeriodGenerationFailure(errorDescription: "遗漏仍被当作周报保存，或未提供失败状态")
                }
            } else {
                guard await responder.count() == 1, let report = model.state.weeklyReports.first,
                      report.modelAssisted, report.dailySynthesisVersion == PeriodReviewFromDaily.synthesisVersion,
                      report.digestRows.count == 8, report.coveredDayCount == 5,
                      model.weeklyReportToOpen == report.id,
                      model.tasks.contains(where: { $0.state == .succeeded }) else {
                    throw PeriodGenerationFailure(errorDescription: "真实周报入口没有调用模型、保存八项完整结果并打开，或仍被五项限制裁掉")
                }
                let export = await model.weeklyMarkdownForExport(report.id)
                let reopened = try FileMemoryStore(storage: model.storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
                let saved = await reopened.snapshot()
                guard export?.components(separatedBy: "\n### ").count == 9, saved.weeklyReports.first?.digestRows.count == 8 else {
                    throw PeriodGenerationFailure(errorDescription: "导出或重启之后再次漏掉第五项之后的内容")
                }
                previous = report
                previous?.editedMarkdown = "# 用户已编辑的原周报\n\n这段合成修订在生成失败后必须保留。"
            }
        }
        print("PASS: native period generation calls the model with all daily items, saves/renders/exports/reopens >5 workstreams, and rejects incomplete results after bounded repair without changing daily/source records")
    }
}
