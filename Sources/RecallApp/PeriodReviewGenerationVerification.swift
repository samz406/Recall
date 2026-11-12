import Foundation
import RecallKit

extension RecallLayoutPreviews {
    private struct PeriodGenerationFailure: LocalizedError { let errorDescription: String? }
    private actor PeriodGenerationModel: LLMResponding {
        enum Mode { case complete, omitOnce, alwaysOmit, malformed }
        let mode: Mode
        var calls = 0
        var sizes: [Int] = []
        init(_ mode: Mode = .complete) { self.mode = mode }
        func count() -> Int { calls }
        func inputSizes() -> [Int] { sizes }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            calls += 1
            guard request.purpose == .reviewSynthesis, let body = request.context.first?.ocrText,
                  let rows = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]], !rows.isEmpty else {
                throw PeriodGenerationFailure(errorDescription: "周期回顾没有把混合类别的十一条每日事项完整交给模型")
            }
            sizes.append(rows.count)
            if calls == 1 {
                guard rows.count == 11,
                      rows.contains(where: { ($0["topic"] as? String)?.hasPrefix("Atlas") == true && ($0["category"] as? String) == "personal" }),
                      rows.contains(where: { ($0["topic"] as? String)?.hasPrefix("Atlas") == true && ($0["category"] as? String) == "learning" }) else {
                    throw PeriodGenerationFailure(errorDescription: "错误的旧分类仍在模型前排除了真实工作")
                }
            }
            let work = rows.filter { ($0["topic"] as? String)?.hasPrefix("Atlas") == true }
            let omit = mode == .alwaysOmit || (mode == .omitOnce && calls == 1)
            let selected = omit ? Array(work.dropLast(min(3, work.count))) : work
            var items = selected.map { row -> [String: Any] in
                ["section": "progress", "title": (row["topic"] as! String) + "验证已完成",
                 "detail": "合成验证的边界条件已核对并记录，生产发布尚待确认。",
                 "evidence": [["id": row["id"]!, "quote": row["title"]!]]]
            }
            if mode == .malformed { items[0].removeValue(forKey: "detail") }
            // A dishonest used receipt without its evidence must not bypass completeness checks.
            let coverage = rows.map { row -> [String: Any] in
                let topic = row["topic"] as! String
                if topic.hasPrefix("Atlas") { return ["id": row["id"]!, "disposition": "used", "category": "work"] }
                return ["id": row["id"]!, "disposition": "outOfScope", "category": topic.hasPrefix("Learning") ? "learning" : "personal",
                    "reason": "原文记录的是私人活动或语言学习，与工作交付无关", "quote": row["detail"]!]
            }
            let value: [String: Any] = ["overview": "八项合成工作均有验证进展，发布仍待确认。", "items": items, "coverage": coverage]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            return LLMAnswer(content: "```json\n{\"result\":" + json + "}\n```", citedCaptureIDs: [])
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
                evidenceIDs: [capture.id], knowledge: DailyItemKnowledge(topic: title, kind: index == 2 || index == 3 ? .reference : .matter, status: "completed",
                    ownedByUser: index != 2 && index != 3, quotes: [capture.ocrText], category: index == 0 ? "personal" : index == 1 ? "learning" : index == 7 ? nil : "work"))
            if let existing = state.dailySummaries.firstIndex(where: { $0.day == day }) {
                state.dailySummaries[existing].items.append(item); state.dailySummaries[existing].sourceCaptureIDs.append(capture.id)
            } else {
                var summary = DailySummary(day: day, content: "合成每日回顾", sourceCaptureIDs: [capture.id], todos: [], generationKind: .cloud, items: [item])
                summary.items = [item]; state.dailySummaries.append(summary)
            }
        }
        for (topic, text, category) in [
            ("Life 合成聚会", "陪家人参加聚会，已安排往返行程和餐食。", "personal"),
            ("Learning 合成练习", "完成英语跟读练习，保留发音笔记与练习录音的文字说明。", "learning"),
            ("Orion 错误标签", "邻居聚会的出行与餐食已安排，这是私人活动。", "work")
        ] {
            let day = state.dailySummaries[0].day
            let source = CaptureRecord(eventTemplate: .workCheckpoint, createdAt: day.addingTimeInterval(40_000),
                contentHash: UUID().uuidString, ocrText: text)
            state.captures.append(source)
            state.dailySummaries[0].sourceCaptureIDs.append(source.id)
            state.dailySummaries[0].items.append(DailySummaryItem(section: .progress, title: topic, detail: text,
                evidenceIDs: [source.id], knowledge: DailyItemKnowledge(topic: topic, kind: .matter, status: "completed",
                    ownedByUser: true, quotes: [text], category: category)))
        }
        let period = ReviewPeriod(start: calendar.date(byAdding: .day, value: -7, to: today)!, end: today)
        var previous: WeeklyReport?
        for mode in [PeriodGenerationModel.Mode.complete, .omitOnce, .alwaysOmit, .malformed] {
            let responder = PeriodGenerationModel(mode)
            var input = state
            if let previous { input.weeklyReports = [previous] }
            let model = try RecallAppModel(previewState: input, dailyReviewResponder: responder)
            defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
            let initial = await model.store.snapshot()
            // Real startup publishes the decoded store snapshot. Previews initially keep their
            // in-memory seed (including subsecond dates); align before checking failure stability.
            model.state = initial
            let originalCaptures = initial.captures, originalDaily = initial.dailySummaries
            _ = await model.store.preparedForChat()
            model.generateWeeklyReview(period: period, template: ReviewTemplate(kind: .work), scope: ReviewScope())
            for _ in 0..<600 {
                if !model.isGeneratingWeeklyReview { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard !model.isGeneratingWeeklyReview, model.state.captures == originalCaptures, model.state.dailySummaries == originalDaily else {
                throw PeriodGenerationFailure(errorDescription: "周期生成状态异常：\(mode)，running=\(model.isGeneratingWeeklyReview)，capturesSame=\(model.state.captures == originalCaptures)，dailySame=\(model.state.dailySummaries == originalDaily)")
            }
            if mode == .alwaysOmit || mode == .malformed {
                guard await responder.count() == 2, model.state.weeklyReports == initial.weeklyReports,
                      model.tasks.contains(where: { $0.state == .failed && ($0.detail?.contains("Read") == true || $0.detail?.contains("读取") == true) }) else {
                    throw PeriodGenerationFailure(errorDescription: "遗漏仍被当作周报保存，或未提供失败状态")
                }
            } else {
                let expectedCalls = mode == .omitOnce ? 2 : 1
                let chatSnapshot = await model.store.preparedForChat()
                guard await responder.count() == expectedCalls, let report = model.state.weeklyReports.first,
                      report.modelAssisted, report.dailySynthesisVersion == PeriodReviewFromDaily.synthesisVersion,
                      report.digestRows.count == 8, report.coveredDayCount == 5,
                      report.items.filter({ $0.id.hasPrefix("reference:model:") && $0.section == .notes }).count == 2,
                      chatSnapshot.weeklyReports.contains(where: { $0.id == report.id }),
                      model.weeklyReportToOpen == report.id,
                      model.tasks.contains(where: { $0.state == .succeeded }) else {
                    throw PeriodGenerationFailure(errorDescription: "真实周报入口没有调用模型、保存八项完整结果并打开，或仍被五项限制裁掉")
                }
                let export = await model.weeklyMarkdownForExport(report.id)
                let reopened = try FileMemoryStore(storage: model.storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
                let saved = await reopened.snapshot()
                guard export?.components(separatedBy: "\n### ").count == 7, saved.weeklyReports.first?.digestRows.count == 8,
                      saved.weeklyReports.first?.readingRows.count == 6,
                      saved.weeklyReports.first?.supplementaryRows.count == 2 else {
                    throw PeriodGenerationFailure(errorDescription: "导出或重启之后再次漏掉第五项之后的内容")
                }
                let sourceLabel = RecallLocalization.both("来源记录提到：", "The source record says: ")
                let requestLabel = RecallLocalization.both("模型请求 \(expectedCalls) 次", "\(expectedCalls) model requests")
                guard export?.contains(sourceLabel) == false, report.supplementaryMarkdown.contains(sourceLabel),
                      model.tasks.contains(where: { $0.state == .succeeded && $0.detail?.contains(requestLabel) == true }),
                      model.diagnosticEntries.contains(where: { $0.source == "WeeklyReview" && $0.metadata["generation"] == "period-from-daily-v4"
                          && $0.metadata["modelCalls"] == String(expectedCalls) && $0.metadata["sourceNotes"] == "2"
                          && $0.metadata["saveSourceCheckMs"] != nil && $0.metadata["saveEncodeMs"] != nil
                          && $0.metadata["saveWriteMs"] != nil && $0.metadata["publishMs"] != nil }) else {
                    throw PeriodGenerationFailure(errorDescription: "归属恢复后仍重复请求、缺少来源限定或未记录实际耗时/请求统计")
                }
                if mode == .omitOnce {
                    guard await responder.inputSizes() == [11, 3] else {
                        throw PeriodGenerationFailure(errorDescription: "原生重试仍然发送整周而不是补齐三条遗漏")
                    }
                }
                previous = report
                previous?.editedMarkdown = "# 用户已编辑的原周报\n\n这段合成修订在生成失败后必须保留。"
            }
        }
        print("PASS: native period generation decodes wrapped results, patches only three omitted inputs, records success/failure timing, preserves unknown attribution and >5 exported/reopened items, and retains edited reports on persistent omission/missing fields")
    }
}
