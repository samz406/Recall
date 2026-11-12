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
                let proofTexts: [String] = topic.hasPrefix("Vega") ? [text] + (1...6).map { "完整引用第\($0)段：Vega 边界条件与验证结果已经保留。" } + ["合成联络地址 fake.person@example.test"] : [text]
                let capture = CaptureRecord(eventTemplate: .workCheckpoint, createdAt: day(offset).addingTimeInterval(36_000),
                    sourceAppName: "Synthetic Notes", contentHash: UUID().uuidString, ocrText: proofTexts.joined(separator: "\n"))
                state.captures.append(capture); sources.append(capture.id)
                let knowledge = DailyItemKnowledge(topic: topic, kind: .matter, status: "inProgress", ownedByUser: true,
                    quotes: proofTexts, category: category)
                let item = DailySummaryItem(section: .progress, title: topic + "已有验证进展", detail: text,
                    evidenceIDs: [capture.id], knowledge: knowledge)
                items.append(item)
                if !highlightOnly {
                    ledger.append(DailyMatterLedgerEntry(topic: topic, kind: .matter, status: "inProgress", section: "progress",
                        title: item.title, detail: text, ownedByUser: true,
                        quotes: proofTexts.map { DailyLedgerQuote(text: $0, sourceIDs: [capture.id], speaker: "user") },
                        evidenceIDs: [capture.id], occurredAt: capture.createdAt, category: category))
                }
            }
            // Fifteen Atlas entries versus seven other independent workstreams.
            for part in 0..<3 { append("Atlas 核心模块\(part + 1)", category: "work") }
            if offset == 1 { append("Nova 跑步活动接口", category: nil) }
            else { append("Nova 独立交付\(offset + 1)", category: "work") }
            if offset == 0 {
                append("Vega 地区列表", category: "personal")
                append("Lyra 前台权限", category: "learning", highlightOnly: true)
                append("LIFE-SYNTHETIC 合成家庭记录", category: "personal", detail: "陪同家人参加聚会，安排了餐食与往返行程。")
                append("LEARNING-SYNTHETIC 合成练习记录", category: "learning", detail: "完成了英语口语跟读练习，保留发音笔记。")
                append("Orion 待核对分类", category: "work", detail: "Orion 邻居聚会的出行与餐食已经安排，属于私人活动。")
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
        enum Mode { case complete, omitOnce, alwaysOmit, falseReceipt, unsupportedExclusion, invalidExclusion, referenceAsProgress, referenceAsPlan }
        let mode: Mode
        var requests: [LLMRequest] = []
        init(_ mode: Mode = .complete) { self.mode = mode }
        func log() -> [LLMRequest] { requests }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            requests.append(request)
            let rows = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
            let target: String? = request.question.contains("模板“我的一周”") ? nil : request.question.contains("模板“学习回顾”") ? "learning" : "work"
            var groups: [String: [[String: Any]]] = [:], coverage: [[String: Any]] = []
            for row in rows {
                let topic = row["topic"] as? String ?? (row["title"] as! String), id = row["id"] as! String
                // This synthetic model judges the fixture's actual subject, never the saved category.
                let actual = topic.hasPrefix("LIFE-") || topic.hasPrefix("Orion") ? "personal" : topic.hasPrefix("LEARNING-") ? "learning" : "work"
                if let target, actual != target {
                    coverage.append(["id": id, "disposition": "outOfScope", "category": actual,
                        "reason": mode == .invalidExclusion && topic.hasPrefix("Orion") ? "" : "原文记录的是其他用途的具体经历，不属于当前模板",
                        "quote": row["detail"]!])
                    continue
                }
                if mode == .unsupportedExclusion, topic.hasPrefix("Nova") {
                    coverage.append(["id": id, "disposition": "outOfScope", "category": "personal",
                        "reason": "尝试没有来源支持的排除", "quote": "没有出现在输入原文中的虚构引用"])
                    continue
                }
                let omitted = topic.hasPrefix("Nova") && (mode == .alwaysOmit || (mode == .omitOnce && requests.count == 1))
                if omitted { continue }
                coverage.append(["id": id, "disposition": "used", "category": actual])
                if mode == .falseReceipt, topic.hasPrefix("Nova") { continue }
                groups[topic.hasPrefix("Atlas") ? "Atlas 核心功能" : topic, default: []].append(row)
            }
            let referenceSection = mode == .referenceAsPlan ? "plans" : mode == .referenceAsProgress ? "progress" : "notes"
            let items = groups.keys.sorted().map { key -> [String: Any] in
                let reference = groups[key]!.allSatisfy { ($0["kind"] as? String)?.contains("reference") == true }
                let section = reference ? referenceSection : "progress"
                return ["section": section, "title": key + (reference ? "相关信息已记录" : "已完成阶段核对"),
                 "detail": reference ? "记录谈及服务维护安排，尚未核实实际影响，不表示用户已经完成该工作。" : key + "的验证结果已记录，边界条件保留，生产发布仍待确认。",
                 "evidence": groups[key]!.map { ["id": $0["id"]!, "quote": $0["title"]!] }]
            }
            let overview = mode == .referenceAsProgress || mode == .referenceAsPlan ? "用户已完成所有维护，后续工作已明确由用户处理。" : groups.isEmpty ? "所选内容中没有符合当前模板的事项。" : "各条事项的进展与当前状态均已按用途整理。"
            let value: [String: Any] = ["overview": overview,
                "items": items, "coverage": coverage]
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), citedCaptureIDs: [])
        }
    }

    static func run() async throws {
        let state = fixture(), engine = PeriodReviewFromDaily()
        let prepared = try engine.prepare(in: state, period: period, template: ReviewTemplate(kind: .work))
        try expect(prepared.itemCount == 26 && prepared.dayCount == 5, "周报未合并完整账本和展示条目，或产生重复输入：\(prepared.itemCount)")
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
            try expect(sent.contains("LIFE-SYNTHETIC") && sent.contains("LEARNING-SYNTHETIC") && sent.contains("完整引用第6段"),
                "模型前仍按类别排除内容，或截掉第四条之后的引用")
            try expect(!sent.contains("fake.person@example.test"), "完整读取时漏掉文本脱敏")
            try expect(report.modelAssisted && report.dailySynthesisVersion == PeriodReviewFromDaily.synthesisVersion,
                "完整周期总结缺少模型或版本标记")
            try expect(report.items.count == 9 && report.digestRows.count == 9 && report.coveredDayCount == 5,
                "显示层仍裁掉第五项之后的独立工作，或遗漏记录日")
            try expect(report.markdown.contains("Vega") && report.markdown.contains("Lyra") && !report.markdown.contains("Orion") && !report.markdown.contains("LIFE-SYNTHETIC") && !report.markdown.contains("LEARNING-SYNTHETIC"), "模型分类后的事项或排除结果没有正确呈现")
            try expect(report.markdown.contains("Nova 跑步活动接口"), "带生活关键词的实际工作仍被本地规则排除")
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
        for mode in [Model.Mode.alwaysOmit, .falseReceipt, .unsupportedExclusion, .invalidExclusion] {
            do {
                _ = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .work), responder: Model(mode))
                throw Failure(errorDescription: "遗漏、假覆盖回执或无依据排除仍被当作完整周报保存")
            } catch ModelReviewError.validation { }
        }
        try await verifyAttributionRecovery(state, engine: engine)
        try await verifyModelClassification(state, engine: engine)
        try await verifyStructuralFilters(state, engine: engine)
        // A selected mislabelled topic is not filtered with its historical personal category.
        let file = DailyKnowledgeEngine().matterFiles(in: state).first { $0.title == "Vega 地区列表" }!
        let scope = ReviewScope(topicIDs: [WeeklyReviewEngine.topicID(for: file)])
        let scoped = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .project), scope: scope,
            topicKeys: [DailyKnowledgeEngine.topicKey(file.title)], responder: Model())
        try expect(scoped.draft.items.count == 1 && scoped.draft.items[0].title.hasPrefix("Vega"), "指定误分类工作主题的范围没有传入模型准备过程")
        var changed = state
        changed.dailySummaries[0].items[0].detail += "更正后的每日展示内容。"
        try expect(DailyKnowledgeEngine().fingerprint(in: state, includingHighlights: true) != DailyKnowledgeEngine().fingerprint(in: changed, includingHighlights: true),
            "生成中每日展示内容变化没有进入并发校验")
        print("PASS: complete period synthesis covers all daily ledger/reading items and workstreams, model classification, >5 rendered/exported items, 15 merged sources, omission repair/rejection and scoped mislabelled topics and fully model-led classification")
    }
    private static func verifyAttributionRecovery(_ state: RecallState, engine: PeriodReviewFromDaily) async throws {
        for mode in [Model.Mode.referenceAsProgress, .referenceAsPlan] {
            let probe = Model(mode)
            let generated = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .work), responder: probe)
            let result = generated.draft
            let report = result.weeklyReport(period: period, template: ReviewTemplate(kind: .work), scope: ReviewScope(), in: state)
            guard let sourceItem = result.items.first(where: { $0.title.hasPrefix("Cetus") }),
                  let note = report.digestRows.first(where: { $0.item.title.hasPrefix("Cetus") }) else {
                throw Failure(errorDescription: "归属不明的来源内容在恢复时丢失")
            }
            let log = await probe.log()
            try expect(log.count == 1 && generated.metrics.modelCalls == 1, "来源条目的栏目不一致仍触发整份周报二次生成")
            try expect(sourceItem.section == "notes" && sourceItem.kind == "reference" && sourceItem.ownedByUser == false
                && note.item.section == .notes && note.action == nil, "来源记录变成了用户成果或个人待办")
            try expect(note.title.hasPrefix("相关记录：") && note.summary.hasPrefix("来源记录提到：")
                && report.markdown.contains("来源记录提到：") && !report.overview.contains("用户已完成"),
                "页面、导出或概览仍无条件声称归属不明的事情由用户完成")
            let facts = result.facts.filter { sourceItem.factIDs.contains($0.id) }
            try expect(!facts.isEmpty && facts.allSatisfy { $0.kind == "reference" && !$0.isAction && $0.attribution == "speaker=unknown" },
                "底层来源仍被记录为本人行动或确定他人身份")
            try expect(report.digestRows.count == 9 && report.items.first(where: { $0.title.hasPrefix("Atlas") })?.section == .progress,
                "恢复来源记录时丢掉其他工作或把已确认的工作也降级")
            let reopened = try JSONDecoder().decode(WeeklyReport.self, from: JSONEncoder().encode(report))
            try expect(reopened.markdown == report.markdown, "重启后来源限定丢失")
        }
        print("PASS: period attribution recovery keeps unknown/reference progress and plans as source-qualified notes in one model call, with no personal action or unsafe overview and no loss after export/reopen")
    }

    private static func verifyModelClassification(_ state: RecallState, engine: PeriodReviewFromDaily) async throws {
        let workInput = try engine.prepare(in: state, period: period, template: ReviewTemplate(kind: .work))
        for kind in ReviewTemplateKind.allCases {
            let input = try engine.prepare(in: state, period: period, template: ReviewTemplate(kind: kind))
            try expect(input.itemCount == workInput.itemCount && input.titles() == workInput.titles(),
                "不同模板在调用模型前筛出了不同的每日内容")
        }
        let probe = Model()
        let personal = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .personal), responder: probe).draft
        let report = personal.weeklyReport(period: period, template: ReviewTemplate(kind: .personal), scope: ReviewScope(), in: state)
        try expect(report.items.count == 12 && report.items.first(where: { $0.title.hasPrefix("Vega") })?.category == .work
            && report.items.first(where: { $0.title.hasPrefix("Orion") })?.category == .personal,
            "模型对错误的历史标签作出纠正后，本地仍拒绝结果或沿用旧类别")
        let learning = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .learning), responder: Model()).draft
        try expect(learning.items.count == 1 && learning.items[0].title.hasPrefix("LEARNING-SYNTHETIC"),
            "学习回顾没有由模型从全量输入中决定范围")
        let emptyWork = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .work),
            topicKeys: [DailyKnowledgeEngine.topicKey("LIFE-SYNTHETIC 合成家庭记录")], responder: Model()).draft
        try expect(emptyWork.items.isEmpty, "仅含生活的范围应交给模型判断无工作，不应本地猜测或凑工作条目")
    }

    private static func verifyStructuralFilters(_ state: RecallState, engine: PeriodReviewFromDaily) async throws {
        var safe = state
        let ids = Array(safe.captures.prefix(3).map(\.id))
        safe.captures[0].sourceBundleIdentifier = "synthetic.excluded"
        safe.privacy.excludedBundleIdentifiers.insert("synthetic.excluded")
        safe.matterCorrections.append(MatterCorrection(evidenceIDs: [ids[1]], kind: .inaccurate))
        safe.captures.removeAll { $0.id == ids[2] }
        let probe = Model()
        let result = try await engine.generate(in: safe, period: period, template: ReviewTemplate(kind: .work), responder: probe).draft
        try expect(ids.allSatisfy { result.sourceVersions[$0] == nil }, "模型主导业务分类时，已删除、失效或隐私排除的来源仍被发送")
        var blocked = state; blocked.privacy.cloudUseEnabled = false
        let noCloud = Model()
        do {
            _ = try await engine.generate(in: blocked, period: period, template: ReviewTemplate(kind: .work), responder: noCloud)
            throw Failure(errorDescription: "云端文本关闭后仍生成周期回顾")
        } catch ModelReviewError.unavailable { }
        let calls = await noCloud.log().count
        try expect(calls == 0, "未授权时仍调用模型")
    }

}
