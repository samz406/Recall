import Foundation

struct PeriodReviewRun: Sendable {
    var metrics = DailyReviewMetrics()
    let started: Date
    let beforeCall: @Sendable () async throws -> Void
    let onProgress: (@Sendable (ReviewGenerationProgress) async -> Void)?
    let onMetrics: (@Sendable (DailyReviewMetrics) async -> Void)?

    mutating func publish() async {
        metrics.totalMilliseconds = Int(Date.now.timeIntervalSince(started) * 1000)
        await onMetrics?(metrics)
    }

    mutating func call(_ request: LLMRequest, detail: String, responder: any LLMResponding) async throws -> String {
        try Task.checkCancellation()
        let check = Date.now
        try await beforeCall()
        metrics.checkMilliseconds += Int(Date.now.timeIntervalSince(check) * 1000)
        await onProgress?(ReviewGenerationProgress(.generating, detail: detail))
        metrics.modelCalls += 1
        let called = Date.now
        do {
            let answer = try await responder.answerCancellably(to: request)
            metrics.modelMilliseconds += Int(Date.now.timeIntervalSince(called) * 1000)
            await publish()
            await onProgress?(ReviewGenerationProgress(.checking, detail: RecallLocalization.both(
                "模型第 \(metrics.modelCalls) 次请求已返回，累计等待 \(max(1, metrics.modelMilliseconds / 1000)) 秒；正在核对来源与覆盖。",
                "Model request \(metrics.modelCalls) returned after \(max(1, metrics.modelMilliseconds / 1000))s total. Checking sources and coverage.")))
            return answer.content
        } catch {
            metrics.modelMilliseconds += Int(Date.now.timeIntervalSince(called) * 1000)
            await publish()
            throw error
        }
    }
}

extension PeriodReviewFromDaily {
    /// Ask only about unresolved input IDs. Accepted text is never sent through a second full
    /// synthesis, and classifications/exclusions still come from the model with verbatim evidence.
    func repairCoverage(_ original: Draft, prepared: Prepared, instructions: String, template: ReviewTemplate?,
                        detailLimit: Int, run: inout PeriodReviewRun, responder: any LLMResponding) async throws -> Draft {
        var ids = coverageIssueIDs(original, prepared: prepared, template: template)
        guard !ids.isEmpty else { return original }
        // Replace whole affected conclusions, never leave their text attached to fewer sources.
        var expanded = true
        while expanded {
            let old = ids
            for item in original.items where !ids.isDisjoint(with: item.evidence.map(\.id)) {
                ids.formUnion(item.evidence.map(\.id))
            }
            expanded = ids != old
        }
        let rows = prepared.rows.filter { ids.contains($0.id) }
        var merged = original
        merged.items.removeAll { !ids.isDisjoint(with: $0.evidence.map(\.id)) }
        merged.coverage = (merged.coverage ?? []).filter { !ids.contains($0.id) }
        // Bounded batches keep a long week's coverage receipt from exhausting one output.
        let batches = stride(from: 0, to: rows.count, by: 24).map { Array(rows[$0..<min($0 + 24, rows.count)]) }
        for (index, batch) in batches.enumerated() {
            let wanted = Set(batch.map(\.id))
            let subset = Prepared(rows: batch, entries: prepared.entries.filter { wanted.contains($0.key) },
                                  sourceVersions: prepared.sourceVersions, dayCount: Set(batch.map(\.date)).count)
            let question = instructions + """

            本次只补齐未通过核对的 \(batch.count) 条输入（第 \(index + 1)/\(batches.count) 组）。其余已通过的结论由程序保留，禁止重写整份回顾。
            coverage 必须恰好覆盖本次输入的每个 id。used 必须同时在本次 items.evidence 引用该 id；outOfScope 仍须给出原文支持的 category/reason/quote。分类完全根据当前实际内容判断，不能沿用历史标签或为了通过检查排除工作。
            overview 返回空字符串；items 只写本次资料可支持的完整结论，证据 id 只能来自本组，不添加新安排。
            """
            let detail = RecallLocalization.both(
                "已保留 \(merged.items.count) 项，正在补齐 \(rows.count) 条待核对输入（\(index + 1)/\(batches.count) 组）。",
                "Keeping \(merged.items.count) verified items; checking \(rows.count) unresolved inputs (batch \(index + 1)/\(batches.count)).")
            let text = try await run.call(LLMRequest(question: question,
                context: [CaptureRecord(eventTemplate: .manualMoment, contentHash: "period-coverage-repair", ocrText: try directReviewJSON(batch))],
                purpose: .reviewSynthesis, outputTokenLimit: 8_000), detail: detail, responder: responder)
            let start = Date.now
            let decoded = try decodeOutput(text)
            let missing = coverageIssueIDs(decoded, prepared: subset, template: template).count
            if missing > 0 {
                await run.onProgress?(ReviewGenerationProgress(.checking, detail: RecallLocalization.both(
                    "补齐第 \(index + 1)/\(batches.count) 组后，仍有 \(missing)/\(batch.count) 条输入未通过覆盖核对；原回顾保留。",
                    "After repair batch \(index + 1)/\(batches.count), \(missing)/\(batch.count) inputs still lack verified coverage. The previous review is preserved.")))
            }
            let patch = try validate(decoded, prepared: subset, itemLimit: max(batch.count, 6),
                                     detailLimit: detailLimit, template: template, complete: true)
            run.metrics.checkMilliseconds += Int(Date.now.timeIntervalSince(start) * 1000)
            merged.items += patch.items
            merged.coverage = (merged.coverage ?? []) + (patch.coverage ?? [])
        }
        // A repaired classification can invalidate the old overview. Use verified model headlines
        // as a record index; all model-written detail and evidence remain in the body.
        merged.overview = recordOverview(merged, prepared: prepared)
        return merged
    }

    func recordOverview(_ draft: Draft, prepared: Prepared) -> String {
        var headlines: [String] = []
        for item in draft.items {
            let sourceOnly = item.evidence.allSatisfy { evidence in
                guard let entry = prepared.entries[evidence.id] else { return true }
                return !entry.knowledge.ownedByUser || entry.knowledge.kind == .reference
            }
            let title = (sourceOnly ? RecallLocalization.both("相关记录：", "Source record: ") : "") + item.title
            if (headlines + [title]).joined(separator: "；").count > 140 { break }
            headlines.append(title)
        }
        return headlines.isEmpty ? "" : RecallLocalization.both("本期记录：", "Period records: ") + headlines.joined(separator: "；") + "。"
    }
}
