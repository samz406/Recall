import Foundation
import RecallKit

/// Synthetic multi-project week. Frequent Atlas updates must not crowd out one-off work,
/// unlabelled work, or a daily reading item missing from its background ledger.
enum PeriodReviewCoverageVerification {
    private struct Failure: LocalizedError { let errorDescription: String? }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(errorDescription: message) }
    }
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value
    }
    private static func day(_ offset: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 19 + offset))!
    }
    private static var period: ReviewPeriod { ReviewPeriod(start: day(0), end: day(7), timeZoneIdentifier: "Asia/Shanghai") }

    private static func fixture() -> RecallState {
        var state = RecallState()
        state.privacy.cloudUseEnabled = true
        for offset in 0..<5 {
            var items: [DailySummaryItem] = [], ledger: [DailyMatterLedgerEntry] = [], sources: [UUID] = []
            func append(_ topic: String, category: String?, highlightOnly: Bool = false, detail: String? = nil) {
                let text = detail ?? "\(topic)已核对第\(offset + 1)天的结果，保留边界条件且尚未发布。"
                let capture = CaptureRecord(eventTemplate: .workCheckpoint, createdAt: day(offset).addingTimeInterval(36_000),
                    sourceAppName: "Synthetic Notes", contentHash: UUID().uuidString, ocrText: text)
                state.captures.append(capture); sources.append(capture.id)
                let knowledge = DailyItemKnowledge(topic: topic, kind: .matter, status: "inProgress", ownedByUser: true,
                    quotes: [text], category: category)
                let item = DailySummaryItem(section: .progress, title: topic + "已有验证进展", detail: text,
                    evidenceIDs: [capture.id], knowledge: knowledge)
                items.append(item)
                if !highlightOnly {
                    ledger.append(DailyMatterLedgerEntry(topic: topic, kind: .matter, status: "inProgress", section: "progress",
                        title: item.title, detail: text, ownedByUser: true,
                        quotes: [DailyLedgerQuote(text: text, sourceIDs: [capture.id], speaker: "user")],
                        evidenceIDs: [capture.id], occurredAt: capture.createdAt, category: category))
                }
            }
            // Fifteen Atlas entries versus seven other independent workstreams.
            for part in 0..<3 { append("Atlas 核心模块\(part + 1)", category: "work") }
            append("Nova 独立交付\(offset + 1)", category: "work")
            if offset == 0 {
                append("Vega 地区列表", category: nil)
                append("Lyra 前台权限", category: "work", highlightOnly: true)
                append("HIDDEN-PERSONAL 合成家庭记录", category: "personal")
                append("HIDDEN-LEARNING 合成练习记录", category: "learning")
                append("Orion 待核对分类", category: nil, detail: "Orion 邻居聚会的出行与餐食已经安排，属于私人活动。")
                // Old daily items without semantic metadata stay visible as source-bound notes.
                let capture = CaptureRecord(eventTemplate: .workCheckpoint, createdAt: day(offset).addingTimeInterval(40_000),
                    contentHash: UUID().uuidString, ocrText: "Cetus 服务公告：服务端将在维护窗口停用部分入口，需另行核实。")
                state.captures.append(capture); sources.append(capture.id)
                items.append(DailySummaryItem(section: .insights, title: "Cetus 服务维护公告", detail: capture.ocrText, evidenceIDs: [capture.id]))
            }
            var review = DailySummary(day: day(offset), content: "合成的每日回顾", sourceCaptureIDs: sources,
                todos: [], generationKind: .cloud, items: items)
            // Keep the archive's local day rather than the CI host's default timezone.
            review.day = day(offset); review.items = items; review.ledger = ledger; state.dailySummaries.append(review)
        }
        return state
    }

    private actor Model: LLMResponding {
        enum Mode { case complete, omitOnce, alwaysOmit, falseReceipt, excludeKnownWork, invalidExclusion }
        let mode: Mode
        var requests: [LLMRequest] = []
        init(_ mode: Mode = .complete) { self.mode = mode }
        func log() -> [LLMRequest] { requests }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            requests.append(request)
            let rows = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
            var groups: [String: [[String: Any]]] = [:], coverage: [[String: Any]] = []
            for row in rows {
                let topic = row["topic"] as? String ?? (row["title"] as! String), id = row["id"] as! String
                if topic.hasPrefix("Orion") {
                    coverage.append(["id": id, "disposition": "outOfScope", "category": "personal",
                        "reason": mode == .invalidExclusion ? "" : "邻居聚会是私人活动，与工作无关", "quote": row["detail"]!])
                    continue
                }
                if mode == .excludeKnownWork, topic.hasPrefix("Nova") {
                    coverage.append(["id": id, "disposition": "outOfScope", "category": "personal", "reason": "试图排除已知的工作内容"])
                    continue
                }
                let omitted = topic.hasPrefix("Nova") && (mode == .alwaysOmit || (mode == .omitOnce && requests.count == 1))
                if omitted { continue }
                coverage.append(["id": id, "disposition": "used", "category": "work"])
                if mode == .falseReceipt, topic.hasPrefix("Nova") { continue }
                groups[topic.hasPrefix("Atlas") ? "Atlas 核心功能" : topic, default: []].append(row)
            }
            let items = groups.keys.sorted().map { key -> [String: Any] in
                let reference = groups[key]!.allSatisfy { ($0["kind"] as? String)?.contains("reference") == true }
                return ["section": reference ? "notes" : "progress", "title": key + (reference ? "相关信息已记录" : "已完成阶段核对"),
                 "detail": reference ? "记录谈及服务维护安排，尚未核实实际影响，不表示用户已经完成该工作。" : key + "的验证结果已记录，边界条件保留，生产发布仍待确认。",
                 "evidence": groups[key]!.map { ["id": $0["id"]!, "quote": $0["title"]!] }]
            }
            let value: [String: Any] = ["overview": "Atlas、Nova、Vega 与 Lyra 各条工作主线均有进展，生产发布尚待确认。",
                "items": items, "coverage": coverage]
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), citedCaptureIDs: [])
        }
    }

    static func run() async throws {
        let state = fixture(), engine = PeriodReviewFromDaily()
        let prepared = try engine.prepare(in: state, period: period, template: ReviewTemplate(kind: .work))
        try expect(prepared.itemCount == 24 && prepared.dayCount == 5, "周报未合并完整账本和展示条目，或产生重复输入：\(prepared.itemCount)")
        try expect(prepared.titles().contains("Vega 地区列表") && prepared.titles().contains("Lyra 前台权限"), "缺失分类或只在每日展示中的事项在模型前消失")
        let gaps = PeriodReviewFromDaily.gaps(in: state, period: period, now: period.end)
        try expect(gaps.reviewedDayCount == 5, "周期统计没有使用档案所在时区的每日回顾")
        for length in ReviewLength.allCases {
            var template = ReviewTemplate(kind: .work); template.length = length
            let probe = Model()
            let generated = try await engine.generate(in: state, period: period, template: template, responder: probe)
            let report = generated.draft.weeklyReport(period: period, template: template, scope: ReviewScope(), in: state)
            let requests = await probe.log(), sent = requests[0].context.map(\.ocrText).joined()
            try expect(requests.count == 1 && requests[0].purpose == .reviewSynthesis, "正常周报应由模型汇总每日回顾，而非本地摘句或先取前五条")
            try expect(!sent.contains("HIDDEN-PERSONAL") && !sent.contains("HIDDEN-LEARNING"), "已知生活和学习内容越过工作模板边界")
            try expect(report.modelAssisted && report.dailySynthesisVersion == PeriodReviewFromDaily.synthesisVersion,
                "完整周期总结缺少模型或版本标记")
            try expect(report.items.count == 9 && report.digestRows.count == 9 && report.coveredDayCount == 5,
                "显示层仍裁掉第五项之后的独立工作，或遗漏记录日")
            try expect(report.markdown.contains("Vega") && report.markdown.contains("Lyra") && !report.markdown.contains("Orion"), "模型分类后的事项或排除结果没有正确呈现")
            try expect(report.items.first(where: { $0.title.hasPrefix("Cetus") })?.section == .notes,
                "旧每日条目没有进入周报，或未知归属被升级为本人工作成果")
            let atlas = report.items.first { $0.title.hasPrefix("Atlas") }!
            try expect(atlas.excerpts.count == 15, "合并同一项目时只保留六或八条来源，导致前几天的内容丢失")
            let reopened = try JSONDecoder().decode(WeeklyReport.self, from: JSONEncoder().encode(report))
            try expect(reopened.digestRows.count == 9 && reopened.markdown == report.markdown,
                "重启或导出后重新套用旧的重点数量限制")
        }
        let repairing = Model(.omitOnce)
        let repaired = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .work), responder: repairing)
        let repairedCalls = await repairing.log().count
        try expect(repairedCalls == 2 && repaired.draft.items.count == 9, "遗漏工作主线没有触发补齐与重新核对")
        for mode in [Model.Mode.alwaysOmit, .falseReceipt, .excludeKnownWork, .invalidExclusion] {
            do {
                _ = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .work), responder: Model(mode))
                throw Failure(errorDescription: "遗漏、假覆盖回执或无依据排除仍被当作完整周报保存")
            } catch ModelReviewError.validation { }
        }
        // A selected unlabelled topic is not accidentally filtered with a default empty scope.
        let file = DailyKnowledgeEngine().matterFiles(in: state).first { $0.title == "Vega 地区列表" }!
        let scope = ReviewScope(topicIDs: [WeeklyReviewEngine.topicID(for: file)])
        let scoped = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .project), scope: scope,
            topicKeys: [DailyKnowledgeEngine.topicKey(file.title)], responder: Model())
        try expect(scoped.draft.items.count == 1 && scoped.draft.items[0].title.hasPrefix("Vega"), "指定未分类工作主题的范围没有传入模型准备过程")
        var changed = state
        changed.dailySummaries[0].items[0].detail += "更正后的每日展示内容。"
        try expect(DailyKnowledgeEngine().fingerprint(in: state, includingHighlights: true) != DailyKnowledgeEngine().fingerprint(in: changed, includingHighlights: true),
            "生成中每日展示内容变化没有进入并发校验")
        print("PASS: complete period synthesis covers all daily ledger/reading items and workstreams, model classification, >5 rendered/exported items, 15 merged sources, omission repair/rejection and scoped unknown topics")
    }
}
