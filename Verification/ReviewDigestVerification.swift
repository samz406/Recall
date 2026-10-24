import Foundation
import RecallKit

/// Invented records only. Tests the complete report contract, not an arbitrary display prefix.
enum ReviewDigestVerification {
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private static func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))!
    }
    private static var period: ReviewPeriod { ReviewPeriod(start: date(18), end: date(25), timeZoneIdentifier: "Asia/Shanghai") }
    private static func note(_ i: Int, day: Int = 20, category: ReviewCategory = .work) throws -> CaptureRecord {
        try ManualMatterNote(title: "Atlas \(i) 号接口验收", detail: "Atlas \(i) 号接口已通过分页验收，尚未确认生产发布。",
            status: .completed, eventAt: date(day), reviewCategory: category).capture(recordedAt: date(day))
    }
    static func run() async throws {
        try await boundedReport()
        try await legacyAndFallback()
        try await balancedSelection()
        try await modelSelection()
        try await rejectedNarratives()
        try await persistenceAndDeletion()
        print("PASS: period digest covers report budgets, legacy material separation, date coverage, selection, rejection and deletion")
    }
    private static func boundedReport() async throws {
        let records = try (0..<173).map { try note($0, day: 18 + $0 % 7) }
        let state = RecallState(captures: records)
        for length in ReviewLength.allCases {
            var template = ReviewTemplate(kind: .personal); template.length = length
            let report = try await WeeklyReviewEngine().generate(in: state, period: period, template: template, now: date(25))
            try expect(report.items.count == 173 && report.sourceIDs.count == 173, "精选不能删除未选中的材料或来源")
            try expect(report.digestRows.count == length.itemLimit && report.digestRows.reduce(0, { $0 + $1.characterCount }) <= length.bodyLimit,
                "173 个候选必须受整份回顾项数及字数限制，不是每项各自长篇输出")
            try expect(report.markdown.components(separatedBy: "\n### ").count - 1 == report.digestRows.count,
                "导出不能绕过正文筛选重新输出所有原文")
            try expect(report.coveredDayCount == 7 && report.overview.count < 240 && !report.overview.contains("尚未确认生产发布"),
                "覆盖天数与概览不能退化为重复的三段正文")
        }
    }
    private static func legacyAndFallback() async throws {
        var report = try await WeeklyReviewEngine().generate(in: RecallState(captures: [note(1)]), period: period,
            template: ReviewTemplate(kind: .personal), now: date(25))
        var reference = report.items[0]
        reference.id = "reference:fixture"; reference.title = "Atlas 接口讨论资料"; reference.section = .notes
        reference.narrative = nil
        reference.excerpts[0].text = "保存的内容（归属与实际状态未确认）：\n" + String(repeating: "这里有一段尚未核对的讨论原文。", count: 30)
        var fragment = reference; fragment.id = "reference:fragment"; fragment.title = "这里最重要的是点击这个再看看。"
        var long = reference; long.id = "reference:long"
        long.narrative = ReviewNarrative(title: "Atlas 接口讨论资料", summary: String(repeating: "讨论原文不能直接代替整份回顾。", count: 50), evidenceIDs: [])
        report.items += [reference, fragment, long]; report.digestTopicIDs = nil
        try expect(report.digestRows.count == 1 && !report.markdown.contains("归属与实际状态未确认") && !report.markdown.contains("讨论原文"),
            "旧回顾不能把未核对、碎片或超长内容继续混入正文")
        let data = try JSONEncoder().encode(report)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "digestTopicIDs")
        let legacy = try JSONDecoder().decode(WeeklyReport.self, from: JSONSerialization.data(withJSONObject: json))
        try expect(legacy.items == report.items && legacy.digestRows.count == 1, "旧数据必须无损读取并应用新的阅读层")
        report.editedMarkdown = "# 用户修订\n\n保留手工写下的完整内容。"
        try expect(report.markdown == report.editedMarkdown, "不允许自动压缩覆盖用户编辑")
        report.editedMarkdown = nil; report.items = [reference]; report.digestTopicIDs = []
        try expect(report.digestRows.isEmpty && report.overview.contains("暂未形成可靠"), "没有可靠小结时应说明情况，不能填充原始记录")
    }
    private static func balancedSelection() async throws {
        var records = try (0..<20).map { try note($0, day: 24) }
        records += [try note(31, day: 18, category: .personal), try note(32, day: 19, category: .learning)]
        let report = try await WeeklyReviewEngine().generate(in: RecallState(captures: records), period: period,
            template: ReviewTemplate(kind: .personal), now: date(25))
        let ids = Set(report.digestRows.flatMap { $0.item.sourceIDs })
        try expect(ids.contains(records[20].id) && ids.contains(records[21].id), "最后一天密集截图不能挤掉整周期早期生活与学习记录")
        let seed = report.items[0]
        var changed = seed; changed.section = .open; changed.id = "state-change"
        var outcome = seed.excerpts[0]; outcome.id = UUID(); outcome.status = .completed
        outcome.text = "接口通过空值测试，但尚未发布。"
        var blocked = outcome; blocked.id = UUID(); blocked.status = .blocked; blocked.date = date(24)
        blocked.text = "最新复核发现重复写入，仍在阻塞发布。"
        changed.excerpts = [outcome, blocked]
        let row = ReviewDigest.row(changed, length: .brief)
        try expect(row?.summary.contains(outcome.text) == true && row?.summary.contains(blocked.text) == true,
            "压缩不能丢掉此前结果或最新否定状态")
        changed.excerpts[1].text = String(repeating: "复核条件仍未满足。", count: 100)
        try expect(ReviewDigest.row(changed, length: .brief) == nil, "不能截断长句或丢掉最新限制来凑篇幅")
    }
    private static func modelSelection() async throws {
        var state = RecallState(captures: try (0..<13).map { try note($0, day: 18 + $0 % 7) })
        state.privacy.cloudUseEnabled = true
        for mode in [DigestProbe.Mode.valid, .empty, .invalidSelection] {
            let probe = DigestProbe(mode: mode)
            let report = try await WeeklyReviewEngine().generate(in: state, period: period,
                template: ReviewTemplate(kind: .personal), responder: probe, now: date(25))
            let requests = await probe.allRequests()
            try expect(requests.first?.purpose == .weeklySelection && report.items.count == 13,
                "大量候选应先筛选，底层材料仍全量保留")
            if mode == .empty {
                try expect(requests.count == 1 && report.digestRows.isEmpty && !report.refinementPending,
                    "模型明确不选任何重点时不得强行回填或无休止重试")
            } else if mode == .valid {
                try expect(requests.count == 3 && report.digestRows.count == 2 && !report.refinementPending,
                    "只对精选两项成文和核验，不应为所有候选分别调用模型")
                try expect(requests[1].context.count == 2 && requests[2].context.count == 2, "核验必须对应真正生成的草稿")
            } else {
                try expect(report.refinementPending && !report.markdown.contains("unknown-topic") && report.digestRows.count <= 5,
                    "非法选择 ID 不能进入回顾，回退仍必须有整份篇幅约束")
            }
        }
        let probe = DigestProbe(mode: .valid); state.privacy.cloudUseEnabled = false
        _ = try await WeeklyReviewEngine().generate(in: state, period: period, template: ReviewTemplate(kind: .personal), responder: probe, now: date(25))
        let count = await probe.allRequests().count
        try expect(count == 0, "关闭云端时筛选也不能外发")
    }
    private static func rejectedNarratives() async throws {
        let reference = CaptureRecord(eventTemplate: .manualMoment, createdAt: date(20), sourceAppName: "合成资料浏览器",
            windowTitle: "Atlas 接口设计资料", contentHash: "synthetic-reference",
            ocrText: String(repeating: "这份资料讨论参数检查、重试边界和重复请求识别，尚未给出完整的回归测试结果，也未说明实际执行者。这段讨论只能作为技术资料，不能确认用户完成了实现。", count: 2))
        var state = RecallState(captures: [reference]); state.privacy.cloudUseEnabled = true
        for mode in [DigestProbe.Mode.auditFails, .tooLong] {
            let report = try await WeeklyReviewEngine().generate(in: state, period: period, template: ReviewTemplate(kind: .personal), responder: DigestProbe(mode: mode), now: date(25))
            try expect(report.refinementPending && report.digestRows.isEmpty && !report.items.isEmpty && report.sourceIDs == [reference.id],
                "模型不可信或超长时只能保留材料，不能以 OCR 原文冒充总结")
        }
    }
    private static func persistenceAndDeletion() async throws {
        let records = try (0..<9).map { try note($0, day: 18 + $0 % 7) }
        let root = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root.rootURL) }
        let store = try FileMemoryStore(storage: root)
        for source in records { try await store.addCapture(source) }
        let state = await store.snapshot()
        let generated = try await WeeklyReviewEngine().generate(in: state, period: period, template: ReviewTemplate(kind: .personal), now: date(25))
        let saved = try await store.commitWeeklyReport(generated, now: date(25))
        let reloaded = try FileMemoryStore(storage: root)
        let loaded = await reloaded.snapshot().weeklyReports.first!
        try expect(loaded.digestTopicIDs == saved.digestTopicIDs && loaded.items.count == 9, "持久化不能丢掉精选顺序或未入选材料")
        let selectedSources = Set(saved.digestRows.flatMap { $0.item.sourceIDs })
        let omitted = records.first { !selectedSources.contains($0.id) }!
        _ = try await store.deleteCapture(id: omitted.id)
        let deleted = await store.snapshot().weeklyReports.first!
        try expect(!deleted.isReadable && deleted.digestTopicIDs == nil && deleted.digestRows.isEmpty,
            "删除未入选的关联材料也必须遵守来源失效规则，不能留下失效摘要")
    }
}

private actor DigestProbe: LLMResponding {
    enum Mode { case valid, empty, invalidSelection, auditFails, tooLong }
    let mode: Mode
    private var requests: [LLMRequest] = []
    init(mode: Mode) { self.mode = mode }
    func allRequests() -> [LLMRequest] { requests }
    func answer(to request: LLMRequest) async throws -> LLMAnswer {
        requests.append(request)
        let topics = try request.context.map { try JSONSerialization.jsonObject(with: Data($0.ocrText.utf8)) as! [String: Any] }
        let output: [String: Any]
        if request.purpose == .weeklySelection {
            let ids = Array(topics.prefix(2)).map { $0["topicID"] as! String }
            output = ["topicIDs": mode == .empty ? [] : (mode == .invalidSelection ? ["unknown-topic"] : ids)]
        } else if request.purpose == .weeklyAudit {
            output = ["checks": topics.map { topic in
                ["topicID": topic["topicID"]!, "supported": mode != .auditFails, "correctAttribution": true,
                 "preservesState": true, "coversKeyFacts": true] as [String: Any]
            }]
        } else {
            output = ["items": topics.map { topic -> [String: Any] in
                let facts = topic["facts"] as! [[String: Any]]
                let text = (topic["evidenceClass"] as? String)?.contains("归属未确认") == true
                    ? "资料讨论了接口参数检查和重试边界，实际执行者与测试结果尚未确认。"
                    : facts.first!["text"] as! String
                return ["topicID": topic["topicID"]!, "title": topic["title"]!,
                    "summary": mode == .tooLong ? String(repeating: text, count: 30) : text,
                    "evidenceIDs": topic["requiredEvidenceIDs"]!]
            }]
        }
        return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self), citedCaptureIDs: [])
    }
}
