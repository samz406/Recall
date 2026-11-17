import Foundation
import RecallKit

extension RecallLayoutPreviews {
    private struct PeriodGenerationFailure: LocalizedError { let errorDescription: String? }
    private actor PeriodGenerationModel: LLMResponding {
        enum Mode { case complete, omitOnce, alwaysOmit, malformed, references, badEvidenceOnce, badEvidenceAlways }
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
            if mode == .references || mode == .badEvidenceOnce || mode == .badEvidenceAlways {
                for i in items.indices {
                    let row = selected[i]
                    items[i]["evidence"] = [["id": row["id"]!, "quoteRef": "title"]]
                }
            }
            if (mode == .badEvidenceOnce && calls == 1) || mode == .badEvidenceAlways {
                items[0]["evidence"] = [["id": selected[0]["id"]!, "quote": "合成的错误引用，原文里没有这句话"]]
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
    private actor PeriodMaintenanceGate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func park() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func hasEntered() -> Bool { entered }
        func release() { continuation?.resume(); continuation = nil }
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
        for mode in [PeriodGenerationModel.Mode.complete, .references, .badEvidenceOnce, .badEvidenceAlways, .omitOnce, .alwaysOmit, .malformed] {
            let responder = PeriodGenerationModel(mode)
            await PeriodReviewFromDaily.discardRetryCheckpoints()
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
            let gate = PeriodMaintenanceGate()
            let maintenance: Task<Bool, Error>? = mode == .complete ? Task {
                try await model.store.organizeMemoryInBackground(force: true, onPreparing: { await gate.park() })
            } : nil
            if maintenance != nil {
                for _ in 0..<200 {
                    if await gate.hasEntered() { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard await gate.hasEntered() else { throw PeriodGenerationFailure(errorDescription: "后台整理并发验证未启动") }
            }
            model.generateWeeklyReview(period: period, template: ReviewTemplate(kind: .work), scope: ReviewScope())
            for _ in 0..<600 {
                if !model.isGeneratingWeeklyReview { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard !model.isGeneratingWeeklyReview, model.state.captures == originalCaptures, model.state.dailySummaries == originalDaily else {
                throw PeriodGenerationFailure(errorDescription: "周期生成状态异常：\(mode)，running=\(model.isGeneratingWeeklyReview)，capturesSame=\(model.state.captures == originalCaptures)，dailySame=\(model.state.dailySummaries == originalDaily)")
            }
            if let maintenance {
                maintenance.cancel(); await gate.release()
                _ = try? await maintenance.value
            }
            if mode == .alwaysOmit || mode == .badEvidenceAlways {
                // The verified majority is saved as an explicitly partial review; the edited original stays.
                let expectedMissing = mode == .alwaysOmit ? 3 : 1
                guard await responder.count() == 2, let saved = model.state.weeklyReports.first,
                      saved.modelCoverage?.unverifiedItemCount == expectedMissing,
                      saved.modelCoverage?.notice?.contains("\(expectedMissing) 条") == true,
                      initial.weeklyReports.allSatisfy({ old in model.state.weeklyReports.contains(old) }),
                      model.tasks.contains(where: { $0.state == .partial && $0.phase.contains("\(expectedMissing) 条事项未通过核对") }) else {
                    throw PeriodGenerationFailure(errorDescription: "持续未通过的少数事项没有以部分回顾保存，或覆盖了用户编辑的原周报：\(mode)")
                }
                // Retrying reuses the verified synthesis and only redoes the failed inputs.
                let retry = PeriodGenerationModel(mode)
                let retryModel = try RecallAppModel(previewState: model.state, dailyReviewResponder: retry)
                defer { try? FileManager.default.removeItem(at: retryModel.storage.rootURL) }
                retryModel.state = await retryModel.store.snapshot()
                retryModel.generateWeeklyReview(period: period, template: ReviewTemplate(kind: .work), scope: ReviewScope())
                for _ in 0..<600 {
                    if !retryModel.isGeneratingWeeklyReview { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard await retry.count() == 1, await retry.inputSizes() == [expectedMissing] else {
                    throw PeriodGenerationFailure(errorDescription: "重新生成仍从头整理整周，而不是只补齐未通过的事项：\(await retry.inputSizes())")
                }
            } else if mode == .malformed {
                guard await responder.count() == 2, model.state.weeklyReports == initial.weeklyReports,
                      model.tasks.contains(where: { $0.state == .failed && ($0.detail?.contains("Read") == true || $0.detail?.contains("读取") == true) }) else {
                    throw PeriodGenerationFailure(errorDescription: "遗漏仍被当作周报保存，或未提供失败状态")
                }
                guard model.tasks.filter({ $0.state == .failed }).allSatisfy({ $0.detail?.contains("正在核对") != true }) else {
                    throw PeriodGenerationFailure(errorDescription: "失败任务仍显示正在核对的过期进度")
                }
            } else {
                let expectedCalls = mode == .omitOnce || mode == .badEvidenceOnce ? 2 : 1
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
                          && $0.metadata["saveWriteMs"] != nil && $0.metadata["publishMs"] != nil
                          && $0.metadata["saveQueueMs"] != nil && $0.metadata["saveTransactionMs"] != nil }) else {
                    throw PeriodGenerationFailure(errorDescription: "归属恢复后仍重复请求、缺少来源限定或未记录实际耗时/请求统计")
                }
                if mode == .omitOnce {
                    guard await responder.inputSizes() == [11, 3] else {
                        throw PeriodGenerationFailure(errorDescription: "原生重试仍然发送整周而不是补齐三条遗漏")
                    }
                }
                if mode == .badEvidenceOnce {
                    guard await responder.inputSizes() == [11, 1] else {
                        throw PeriodGenerationFailure(errorDescription: "引用修复仍发送整周数据或丢弃已通过结论")
                    }
                }
                previous = report
                previous?.editedMarkdown = "# 用户已编辑的原周报\n\n这段合成修订在生成失败后必须保留。"
            }
        }
        try await verifyEmptyBodyAndBackfillChain(state: state, period: period)
        print("PASS: native period generation resolves quote references, repairs only one bad citation or three omitted inputs, records success/failure timing, preserves unknown attribution and >5 exported/reopened items, saves persistent omissions/bad citations as counted partial reviews and retries only those inputs, retains edited reports on missing fields, refuses empty work bodies and chains missing daily reviews into the period review")
    }

    /// Answers every daily review with one owned matter, and every period review with related records only
    /// (empty body) or with one progress item, so both the refusal and the chained generation are observable.
    private actor ChainModel: LLMResponding {
        let emptyBody: Bool
        var daily = 0, period = 0
        init(emptyBody: Bool) { self.emptyBody = emptyBody }
        func counts() -> (daily: Int, period: Int) { (daily, period) }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            if request.purpose == .personaInsight { return LLMAnswer(content: "{\"traits\":[]}", citedCaptureIDs: []) }
            guard let body = request.context.first?.ocrText,
                  let rows = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]], let first = rows.first else {
                throw PeriodGenerationFailure(errorDescription: "合成模型收到无法解析的输入")
            }
            if first["text"] != nil {
                daily += 1
                let id = first["id"] as! String
                let quote = (first["quotes"] as? [String])?.first ?? (first["text"] as! String).components(separatedBy: "\n").last!
                let item: [String: Any] = ["section": "progress", "title": "Atlas 合成补生成验证完成", "detail": "Atlas 合成补生成的验证结果已记录，原始来源保留。",
                    "owner": "user", "status": "completed", "explicitCommitment": false, "condition": NSNull(), "evidence": [["id": id, "quote": quote]]]
                let coverage = rows.map { ["id": $0["id"]!, "disposition": ($0["id"] as? String) == id ? "used" : "background"] }
                let value: [String: Any] = ["overview": "Atlas 合成补生成验证结果已记录。", "items": [item], "coverage": coverage]
                return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), citedCaptureIDs: [])
            }
            period += 1
            let items = rows.map { row -> [String: Any] in
                ["section": emptyBody ? "notes" : "progress", "title": (row["topic"] as? String ?? "合成") + "验证记录",
                 "detail": "合成验证的过程与结论已记录，来源保留。", "evidence": [["id": row["id"]!, "quote": row["title"]!]]]
            }
            let coverage = rows.map { ["id": $0["id"]!, "disposition": "used", "category": "work"] }
            let value: [String: Any] = ["overview": "合成回顾。", "items": items, "coverage": coverage]
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    @MainActor private static func verifyEmptyBodyAndBackfillChain(state seed: RecallState, period: ReviewPeriod) async throws {
        func wait(_ model: RecallAppModel) async throws {
            for _ in 0..<800 {
                if !model.isGeneratingWeeklyReview && !model.isGeneratingDailySummary && model.pendingPeriodReview == nil { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw PeriodGenerationFailure(errorDescription: "补生成与周期回顾没有在时限内结束")
        }
        // 1. A work review whose model output contains only related records is not saved.
        var input = seed; input.llmConfiguration.credentialReference = UUID().uuidString
        let refusing = ChainModel(emptyBody: true)
        let empty = try RecallAppModel(previewState: input, dailyReviewResponder: refusing)
        defer { try? FileManager.default.removeItem(at: empty.storage.rootURL) }
        empty.state = await empty.store.snapshot()
        let before = empty.state.weeklyReports
        empty.generateWeeklyReview(period: period, template: ReviewTemplate(kind: .project), scope: ReviewScope())
        try await wait(empty)
        guard empty.state.weeklyReports == before,
              empty.tasks.contains(where: { $0.state == .failed && $0.phase.contains("相关记录") && $0.phase.contains("未保存") }) else {
            throw PeriodGenerationFailure(errorDescription: "没有正文的工作回顾仍被保存，或未说明原因")
        }
        // 2. Missing days are generated first; the period review follows without another click.
        let calendar = Calendar.current
        var gapped = input
        let missingDay = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: .now))!
        gapped.captures.append(CaptureRecord(eventTemplate: .manualMoment, createdAt: missingDay.addingTimeInterval(36_000), sourceAppName: "Synthetic Notes",
            contentHash: UUID().uuidString, ocrText: "Atlas 合成补生成验证已经完成，这一天还没有每日回顾。", textOrigin: .userInput))
        let chain = ChainModel(emptyBody: false)
        let model = try RecallAppModel(previewState: gapped, dailyReviewResponder: chain)
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        model.state = await model.store.snapshot()
        let gaps = PeriodReviewFromDaily.gaps(in: model.state, period: period)
        guard gaps.missingRecordedDays.contains(where: { calendar.isDate($0, inSameDayAs: missingDay) }) else {
            throw PeriodGenerationFailure(errorDescription: "生成前没有识别出缺失的每日回顾")
        }
        model.backfillThenGenerateWeeklyReview(days: gaps.allMissingDays, period: period, template: ReviewTemplate(kind: .personal), scope: ReviewScope())
        guard model.pendingPeriodReview != nil || model.isGeneratingDailySummary else {
            throw PeriodGenerationFailure(errorDescription: "补生成没有排队")
        }
        try await wait(model)
        let counts = await chain.counts()
        guard counts.daily >= 1, counts.period == 1, model.state.dailyReview(on: missingDay) != nil,
              let saved = model.state.weeklyReports.first, !saved.hasNoBody, model.weeklyReportToOpen == saved.id else {
            throw PeriodGenerationFailure(errorDescription: "补生成后没有自动生成周期回顾（每日 \(counts.daily) 次，周期 \(counts.period) 次）")
        }
        // 3. Regenerating the same range adds a version, grouped under one review.
        model.generateWeeklyReview(period: period, template: ReviewTemplate(kind: .personal), scope: ReviewScope())
        try await wait(model)
        let groups = ReviewVersionGroup.groups(model.state.weeklyReports)
        guard model.state.weeklyReports.count == 2, groups.count == 1, groups[0].versions.count == 2 else {
            throw PeriodGenerationFailure(errorDescription: "同一时间段重新生成没有归为同一份回顾的新版本")
        }
    }
}
