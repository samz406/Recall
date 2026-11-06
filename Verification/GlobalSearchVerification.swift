import Foundation
import RecallKit

enum GlobalSearchVerification {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(errorDescription: message) }
    }
    static func record(_ text: String, at date: Date = .now, app: String = "Synthetic Notes") -> CaptureRecord {
        CaptureRecord(eventTemplate: .manualMoment, createdAt: date, sourceAppName: app, sourceBundleIdentifier: "synthetic.notes",
            contentHash: "unchanged-hash", ocrText: text, textOrigin: .userInput)
    }
    static func run() async throws {
        try fullTextAndCorrections()
        try await scopesAndVersions()
        try await datesAndTopicEvents()
        try await largeArchiveAndCancellation()
        print("PASS: global search full-text tails, corrected text, six categories, provenance/version/expiry gates, date intervals, topic events and cancellation")
    }
    private static func fullTextAndCorrections() throws {
        var corrected = record("OldOnlyToken 旧文本"); corrected.correctedText = "CorrectedOnlyToken 用户更正"
        var archived = record("InternalArchiveToken"); archived.isMemoryEvidenceArchive = true
        var generated = record("GeneratedReviewToken"); generated.eventTemplate = .dailyReview
        let tail = record(String(repeating: "合成的长记录正文。", count: 4_000) + " TailNeedleToken 最后一个段落")
        let other = record("[聊天·对方] SavedReferenceToken 对方保存的资料", app: "Synthetic Chat")
        let state = RecallState(captures: [corrected, archived, generated, tail, other])
        let search = GlobalMemorySearch(state: state, matters: [])
        let found = search.search("tailneedletoken")
        try expect(found.count == 1 && found[0].sourceIDs == [tail.id] && found[0].detail.contains("TailNeedleToken")
            && found[0].detail.count <= 302, "长正文尾部漏搜，或摘要不包含命中位置/长度无界")
        try expect(search.search("OldOnlyToken").isEmpty && search.search("CorrectedOnlyToken").count == 1, "纠正后仍搜到旧 OCR")
        try expect(search.search("tAiLnEeDlEtOkEn").count == 1 && search.search("用户更正").count == 1, "ASCII 大小写或中文完整片段匹配失败")
        try expect(search.search("InternalArchiveToken").isEmpty && search.search("GeneratedReviewToken").isEmpty, "内部副本冒充原始记录")
        try expect(search.search("SavedReferenceToken").count == 1, "对方内容或保存资料不能作为原始记录检索")
        try expect(search.search("").isEmpty && search.search("TailNeedleToken", limit: 0).isEmpty, "空搜索/零条上限仍产生结果")
        try expect(search.search("", app: "Synthetic Chat").count == 1, "只筛选来源不能查询")
    }
    private static func scopesAndVersions() async throws {
        let source = try ManualMatterNote(title: "Atlas 账单验收", detail: "Atlas 账单已经完成边界核对，待提交评审。", status: .progressed, eventAt: .now).capture()
        let directive = MemoryDirective.parse("记住：以后回答简洁一点，先结论后细节")!
        let preference = CaptureRecord(eventTemplate: .manualMoment, sourceAppName: "Synthetic Notes", contentHash: "preference",
            ocrText: directive.content, textOrigin: .userInput, memoryDirective: directive)
        var state = RecallState(captures: [source, preference])
        var daily = DailySummary(day: source.createdAt, content: "历史正文独有 LegacyBodyToken", sourceCaptureIDs: [source.id],
            todos: [], generationKind: .cloud)
        daily.items = []; daily.modelOverview = "概览独有 OverviewOnlyToken"
        state.dailySummaries = [daily]
        state.reminders = [ReminderCandidate(title: "Atlas 账单复核", detail: "核对具体内容", sourceCaptureIDs: [source.id], confidence: 1),
            ReminderCandidate(title: "ManualOnlyToken 手动提醒", detail: "没有截图来源", confidence: 1, origin: .manual),
            ReminderCandidate(title: "OrphanCandidateToken", detail: "", confidence: 1)]
        let report = try await WeeklyReviewEngine().generate(in: state, period: ReviewPeriod.make(.recentSeven), template: ReviewTemplate(kind: .personal))
        state.weeklyReports = [report]
        state.memoryKnowledge = MemoryKnowledgeEngine().reconcile(state, force: true)
        let files = MatterMemoryEngine().files(in: state), index = GlobalMemorySearch(state: state, matters: files)
        try expect(Set(index.search("Atlas").map(\.kind)).isSuperset(of: ["原始记录", "记忆主题", "周期回顾", "提醒"]), "全局搜索丢失可读内容类型")
        try expect(index.search("LegacyBodyToken").contains { $0.kind == "每日回顾" }
            && index.search("OverviewOnlyToken").contains { $0.kind == "每日回顾" }, "旧版正文/当天概览漏搜")
        try expect(index.search("简洁").contains { $0.kind == "长期记忆" }, "有效长期偏好无法搜索")
        try expect(index.search("ManualOnlyToken").count == 1 && index.search("OrphanCandidateToken").isEmpty, "手动提醒丢失或无来源自动候选被放行")
        if var claim = state.memoryKnowledge.claims.first(where: { $0.kind == .preference && $0.usable() }) {
            claim.id = UUID(); claim.title = "ExpiringToken"; claim.content = "ExpiringToken"
            let now = Date.now; claim.validUntil = now.addingTimeInterval(60)
            state.memoryKnowledge.claims = [claim]
            let expiring = GlobalMemorySearch(state: state, matters: [], now: now)
            let future = try expiring.result(for: .init(text: "ExpiringToken"), now: now.addingTimeInterval(61))
            try expect(!expiring.search("ExpiringToken").isEmpty
                && future.isEmpty, "旧索引在长期记忆到期后仍返回该内容")
            claim.scope = .conversation; state.memoryKnowledge.claims = [claim]
            try expect(GlobalMemorySearch(state: state, matters: []).search("ExpiringToken").isEmpty, "临时会话约定进入长期检索")
            claim.scope = .global; claim.kind = .reference; claim.title = "SavedReferenceMemoryToken"; claim.content = "SavedReferenceMemoryToken"
            state.memoryKnowledge.claims = [claim]
            try expect(GlobalMemorySearch(state: state, matters: []).search("SavedReferenceMemoryToken").count == 1, "保存的资料线索被检索范围排除")
        } else { throw Failure(errorDescription: "合成长期记忆未生成") }
        var edited = state; edited.captures[0].correctedText = "Atlas 账单已撤回，本条文字已由用户更正。"
        try expect(!GlobalMemorySearch(state: edited, matters: []).search("Atlas").contains { $0.kind == "周期回顾" }, "原始文字变更后仍搜索到旧版本周期回顾")
        var invalid = state
        invalid.matterCorrections = [MatterCorrection(evidenceIDs: [source.id], kind: .notMine)]
        let corrected = GlobalMemorySearch(state: invalid, matters: files).search("Atlas")
        try expect(corrected.allSatisfy { $0.kind == "原始记录" }, "纠正后派生结论仍参与检索")
        invalid.privacy.excludedBundleIdentifiers.insert(source.sourceBundleIdentifier ?? "")
        try expect(GlobalMemorySearch(state: invalid, matters: files).search("Atlas").isEmpty, "排除的应用仍返回内容")
        invalid = state; invalid.captures.removeAll { $0.id == source.id }
        try expect(GlobalMemorySearch(state: invalid, matters: files).search("Atlas").isEmpty, "删除后的来源或派生结果仍可搜索")
    }
    private static func datesAndTopicEvents() async throws {
        let calendar = Calendar.current
        let first = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -4, to: .now)!)
        let second = calendar.date(byAdding: .day, value: 1, to: first)!
        let end = calendar.date(byAdding: .day, value: 2, to: first)!
        let a = try ManualMatterNote(title: "Atlas 日期边界", detail: "FirstDayToken 已完成具体方案并保存可核验的结果。", status: .completed, eventAt: first).capture(recordedAt: first)
        let b = record("SecondDayToken", at: second)
        let events = [
            MatterEvent(id: UUID(), title: "跨日主题", detail: "FirstDayTopicToken", recordedAt: first, status: .progressed, evidenceIDs: [a.id]),
            MatterEvent(id: UUID(), title: "跨日主题", detail: "SecondDayTopicToken", recordedAt: second, status: .completed, evidenceIDs: [b.id])]
        let file = MatterFile(id: "synthetic-topic", title: "跨日主题", events: events)
        var state = RecallState(captures: [a, b])
        var report = try await WeeklyReviewEngine().generate(in: state, period: ReviewPeriod(start: first, end: end), template: ReviewTemplate(kind: .personal))
        report.createdAt = .now; report.updatedAt = .now; report.editedMarkdown = "PeriodBodyToken"
        state.weeklyReports = [report]
        let index = GlobalMemorySearch(state: state, matters: [file])
        try expect(index.search("FirstDayTopicToken", start: first, end: second).contains { $0.kind == "记忆主题" }
            && index.search("FirstDayTopicToken", start: second, end: end).isEmpty, "主题按最后更新日期误筛选或跨日期混用正文")
        try expect(index.search("PeriodBodyToken", start: first, end: second).count == 1
            && index.search("PeriodBodyToken", start: end).isEmpty, "周期回顾按生成日期筛选或区间边界错误")
        try expect(index.search("", start: first, end: second).filter { $0.kind == "原始记录" }.map(\.destination) == [.record(a.id)], "限定日期包含了终点日的记录")
        try expect(index.search("SecondDayToken", topicSources: [a.id]).isEmpty, "主题来源筛选没有生效")
    }
    private static func largeArchiveAndCancellation() async throws {
        let body = String(repeating: "合成正文，不应为打开搜索反复概括。", count: 500)
        var records = (0..<6_351).map { i in
            var r = record(body); r.summary = "合成记录 \(i)"; return r
        }
        records[6_350].ocrText += " UniqueTail6351"
        let started = Date.now, index = GlobalMemorySearch(state: RecallState(captures: records), matters: [])
        let built = Date.now, found = index.search("UniqueTail6351")
        try expect(found.count == 1 && found[0].sourceIDs == [records[6_350].id], "大存档只检索了前缀或前几个记录")
        print("PERF: global search 6351 large-text records, metadata build \(Int(built.timeIntervalSince(started) * 1000)) ms; tail query \(Int(Date.now.timeIntervalSince(built) * 1000)) ms (synthetic)")
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try index.result(for: .init(text: "合成"))
        }
        task.cancel()
        do { _ = try await task.value; throw Failure(errorDescription: "过期查询未取消") } catch is CancellationError { }
    }
}

