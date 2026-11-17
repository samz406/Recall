import Foundation

struct PeriodReviewRun: Sendable {
    var metrics = DailyReviewMetrics()
    let started: Date
    let beforeCall: @Sendable () async throws -> Void
    let sourceCheck: (@Sendable () async throws -> Int)?
    let onProgress: (@Sendable (ReviewGenerationProgress) async -> Void)?
    let onMetrics: (@Sendable (DailyReviewMetrics) async -> Void)?

    mutating func publish() async {
        metrics.totalMilliseconds = Int(Date.now.timeIntervalSince(started) * 1000)
        await onMetrics?(metrics)
    }

    mutating func call(_ request: LLMRequest, detail: String, responder: any LLMResponding) async throws -> String {
        try Task.checkCancellation()
        try await checkSources()
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

    mutating func checkSources() async throws {
        let started = Date.now, check = sourceCheck, fallback = beforeCall
        do {
            let elapsed = try await LocalOperation.run(stage: "确认回顾来源") {
                if let check { return try await check() }
                try await fallback(); return 0
            }
            metrics.checkMilliseconds += elapsed
            metrics.sourceWaitMilliseconds += max(0, Int(Date.now.timeIntervalSince(started) * 1000) - elapsed)
        } catch {
            metrics.sourceWaitMilliseconds += Int(Date.now.timeIntervalSince(started) * 1000)
            throw error
        }
    }
}

extension PeriodReviewFromDaily {
    struct RepairOutcome: Sendable {
        var draft: Draft
        /// Inputs that still have no verified conclusion or receipt after the scoped repair.
        var unresolvedIDs: Set<String>
        var issue: ModelValidationIssue?
    }

    /// Ask only about unresolved input IDs. Accepted text is never sent through a second full
    /// synthesis, and classifications/exclusions still come from the model with verbatim evidence.
    /// A batch that still fails does not discard other verified batches: its inputs are returned as
    /// unresolved, and the caller decides whether a clearly marked partial review may be saved.
    func repairCoverage(_ original: Draft, prepared: Prepared, instructions: String, template: ReviewTemplate?,
                        detailLimit: Int, forcedIDs: Set<String> = [], rejections: [Rejection] = [], includeMissingCoverage: Bool = true,
                        run: inout PeriodReviewRun, responder: any LLMResponding) async throws -> RepairOutcome {
        var ids = forcedIDs
        if includeMissingCoverage { ids.formUnion(coverageIssueIDs(original, prepared: prepared, template: template)) }
        let known = Set(prepared.rows.map(\.id))
        guard !ids.isEmpty else { return RepairOutcome(draft: original, unresolvedIDs: [], issue: nil) }
        // Replace whole affected conclusions, never leave their text attached to fewer sources.
        ids = Self.closure(ids, items: original.items)
        let rows = prepared.rows.filter { ids.contains($0.id) }
        var merged = original
        merged.items.removeAll { !ids.isDisjoint(with: $0.evidence.map(\.id)) }
        merged.coverage = (merged.coverage ?? []).filter { known.contains($0.id) && !ids.contains($0.id) }
        var unresolved: Set<String> = [], lastIssue: ModelValidationIssue?
        // Bounded batches keep a long week's coverage receipt from exhausting one output.
        let batches = stride(from: 0, to: rows.count, by: 24).map { Array(rows[$0..<min($0 + 24, rows.count)]) }
        for (index, batch) in batches.enumerated() {
            let wanted = Set(batch.map(\.id))
            let subset = Prepared(rows: batch, entries: prepared.entries.filter { wanted.contains($0.key) },
                                  sourceVersions: prepared.sourceVersions, dayCount: Set(batch.map(\.date)).count)
            let question = instructions + """

            本次只补齐未通过核对的 \(batch.count) 条输入（第 \(index + 1)/\(batches.count) 组）。其余已通过的结论由程序保留，禁止重写整份回顾。
            coverage 必须恰好覆盖本次输入的每个 id。used 必须同时在本次 items.evidence 引用该 id；outOfScope 仍须给出原文支持的 category/reason/quoteRef（或逐字 quote）。分类完全根据当前实际内容判断，不能沿用历史标签或为了通过检查排除工作。
            overview 返回空字符串；items 只写本次资料可支持的完整结论，证据 id 只能来自本组，不添加新安排。优先使用 quoteRef=title/detail/q1/q2/…选择现有字段，不重复抄写原文；不能通过删除某条引用而保留仍依赖它的结论。
            """ + Self.repairNotes(rejections, batch: wanted, missing: wanted.intersection(forcedIDs.union(
                includeMissingCoverage ? coverageIssueIDs(original, prepared: prepared, template: template) : [])))
            let detail = RecallLocalization.both(
                "已保留 \(merged.items.count) 项，正在补齐 \(rows.count) 条待核对输入（\(index + 1)/\(batches.count) 组）。",
                "Keeping \(merged.items.count) verified items; checking \(rows.count) unresolved inputs (batch \(index + 1)/\(batches.count)).")
            let text = try await run.call(LLMRequest(question: question,
                context: [CaptureRecord(eventTemplate: .manualMoment, contentHash: "period-coverage-repair", ocrText: try directReviewJSON(batch))],
                purpose: .reviewSynthesis, outputTokenLimit: min(8_000, max(2_000, batch.count * (detailLimit * 2 + 160)))), detail: detail, responder: responder)
            let start = Date.now
            defer { run.metrics.checkMilliseconds += Int(Date.now.timeIntervalSince(start) * 1000) }
            let assessment: EvidenceAssessment
            do {
                assessment = try assessEvidence(decodeOutput(text), prepared: subset, itemLimit: max(batch.count, 6),
                    detailLimit: detailLimit, template: template, complete: true)
            } catch is PeriodReviewOutputFailure {
                unresolved.formUnion(wanted); lastIssue = .format; continue
            } catch ModelReviewError.validation(let issue) {
                unresolved.formUnion(wanted); lastIssue = issue; continue
            }
            // Keep every verified conclusion of this batch; drop only those touching a failed input.
            var failed = assessment.unresolvedIDs.union(coverageIssueIDs(assessment.draft, prepared: subset, template: template))
            failed = Self.closure(failed, items: assessment.draft.items).intersection(wanted)
            var patch = assessment.draft
            patch.items.removeAll { !failed.isDisjoint(with: $0.evidence.map(\.id)) }
            patch.coverage = (patch.coverage ?? []).filter { wanted.contains($0.id) && !failed.contains($0.id) }
            if !failed.isEmpty {
                lastIssue = assessment.firstIssue ?? .importantContentMissing
                unresolved.formUnion(failed)
                await run.onProgress?(ReviewGenerationProgress(.checking, detail: RecallLocalization.both(
                    "补齐第 \(index + 1)/\(batches.count) 组后，仍有 \(failed.count)/\(batch.count) 条输入未通过核对；其余结论已保留。",
                    "After repair batch \(index + 1)/\(batches.count), \(failed.count)/\(batch.count) inputs still fail checks. Other conclusions are kept.")))
            }
            do {
                patch = try validate(patch, prepared: subset, itemLimit: max(batch.count, 6),
                                     detailLimit: detailLimit, template: template, complete: true, checkCoverage: false)
            } catch ModelReviewError.validation(let issue) {
                unresolved.formUnion(wanted); lastIssue = issue; continue
            }
            merged.items += patch.items
            merged.coverage = (merged.coverage ?? []) + (patch.coverage ?? [])
        }
        // A repaired classification can invalidate the old overview. Use verified model headlines
        // as a record index; all model-written detail and evidence remain in the body.
        merged.overview = recordOverview(merged, prepared: prepared)
        return RepairOutcome(draft: merged, unresolvedIDs: unresolved, issue: lastIssue)
    }

    /// Inputs cited together by one conclusion stand or fall together.
    static func closure(_ seed: Set<String>, items: [Draft.Item]) -> Set<String> {
        var ids = seed, expanded = true
        while expanded {
            let old = ids
            for item in items where !ids.isDisjoint(with: item.evidence.map(\.id)) { ids.formUnion(item.evidence.map(\.id)) }
            expanded = ids != old
        }
        return ids
    }

    /// Tell the model exactly which conclusion failed and why, instead of only "fix these inputs".
    /// Titles are the model's own redacted output; ids refer to the redacted rows already in this batch.
    static func repairNotes(_ rejections: [Rejection], batch: Set<String>, missing: Set<String>) -> String {
        var lines: [String] = []
        for rejection in rejections where !batch.isDisjoint(with: rejection.ids) || rejection.ids.isEmpty {
            let cited = rejection.ids.filter(batch.contains)
            let ids = cited.isEmpty ? "" : "（引用 " + cited.joined(separator: "、") + "）"
            lines.append("- 上次写在 \(rejection.section) 的“\(rejection.title)”\(ids)未通过：\(rejection.issue.explanation)。\(rejection.issue.repairInstruction)")
        }
        let rejected = Set(rejections.flatMap(\.ids))
        let uncovered = missing.subtracting(rejected).sorted()
        if !uncovered.isEmpty {
            lines.append("- 以下输入上次没有对应的结论或 coverage：\(uncovered.joined(separator: "、"))。逐条核对后成文或给出有原文依据的 outOfScope。")
        }
        guard !lines.isEmpty else { return "" }
        return "\n上次未通过的具体原因（逐条修正，不要重复同样的问题）：\n" + lines.prefix(24).joined(separator: "\n")
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
