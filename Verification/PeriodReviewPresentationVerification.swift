import Foundation
import RecallKit

/// Synthetic contracts for empty period bodies, daily-review coverage before generation and version grouping.
enum PeriodReviewPresentationVerification {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(errorDescription: message) } }

    static func run() throws {
        try emptyBody()
        try todayCoverage()
        try versionGroups()
        print("PASS: 3 period-review presentation scenarios (empty work body with only related records, today reported separately with an exclude-today period, same-range versions grouped newest first)")
    }

    /// Built through the archive's decoder, the same path saved reports take.
    static func report(_ template: ReviewTemplate, items: [ReviewItem], period: ReviewPeriod, createdAt: Date = .now) -> WeeklyReport {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        func json<T: Encodable>(_ value: T) -> Any { try! JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed]) }
        let stamp = ISO8601DateFormatter().string(from: createdAt)
        let object: [String: Any] = ["id": UUID().uuidString, "createdAt": stamp, "updatedAt": stamp, "period": json(period),
            "template": json(template), "scope": json(ReviewScope()), "items": json(items), "sourceVersions": [Any](),
            "modelAssisted": true, "dailySynthesisVersion": PeriodReviewFromDaily.synthesisVersion, "digestTopicIDs": items.map(\.id),
            "refinementPending": false]
        return try! decoder.decode(WeeklyReport.self, from: JSONSerialization.data(withJSONObject: object))
    }
    static func item(_ section: ReviewSection, _ title: String) -> ReviewItem {
        let excerpt = ReviewExcerpt(id: UUID(), date: Calendar.current.startOfDay(for: .now).addingTimeInterval(-43_200),
                                    text: title + "的合成说明，已记录完整的验证过程。", status: .completed, sourceIDs: [UUID()])
        return ReviewItem(id: "model:" + UUID().uuidString, title: title, category: .work, section: section, previous: nil, excerpts: [excerpt],
                   featuredIDs: [excerpt.id], nextAction: nil, nextActionSourceIDs: [],
                   narrative: ReviewNarrative(title: title, summary: title + "已核对，合成验证的过程与结论均已记录。", evidenceIDs: [excerpt.id]))
    }

    static func emptyBody() throws {
        let today = Calendar.current.startOfDay(for: .now)
        let period = ReviewPeriod(start: today.addingTimeInterval(-86_400), end: today)
        let work = ReviewTemplate(kind: .project)
        let notesOnly = report(work, items: [item(.notes, "合成相关记录甲"), item(.notes, "合成相关记录乙")], period: period)
        try expect(notesOnly.hasNoBody && notesOnly.supplementaryRows.count == 2, "只有相关记录的工作回顾没有被识别为无正文")
        try expect(notesOnly.readingOverview.isEmpty, "无正文时仍显示指向“查看来源”的固定句子")
        try expect(!notesOnly.markdown.contains("查看来源"), "导出内容仍包含无效的入口说明")
        let personal = report(ReviewTemplate(kind: .personal), items: [item(.notes, "合成相关记录甲")], period: period)
        try expect(!personal.hasNoBody, "个人模板的记录被误判为无正文")
        let withBody = report(work, items: [item(.progress, "合成交付完成"), item(.notes, "合成相关记录")], period: period)
        try expect(!withBody.hasNoBody && withBody.readingOverview.contains("合成交付完成"), "有正文的回顾概览不正确")
        var edited = notesOnly; edited.editedMarkdown = "用户自己写的正文"
        try expect(!edited.hasNoBody, "用户编辑过的回顾被当作无正文")
        let error = WeeklyReviewError.noReadableContent(template: work.name, relatedCount: 2)
        try expect(error.errorDescription?.contains("2 条相关记录") == true && error.errorDescription?.contains("未保存") == true, "无正文的说明没有给出原因")
    }

    static func todayCoverage() throws {
        let calendar = Calendar.current
        let now = calendar.date(bySettingHour: 11, minute: 27, second: 0, of: .now)!
        let today = calendar.startOfDay(for: now), yesterday = today.addingTimeInterval(-86_400), twoDaysAgo = today.addingTimeInterval(-2 * 86_400)
        var state = RecallState(); state.privacy.cloudUseEnabled = true
        for day in [twoDaysAgo, yesterday, today] {
            state.captures.append(CaptureRecord(eventTemplate: .manualMoment, createdAt: day.addingTimeInterval(3_600), contentHash: UUID().uuidString,
                                                ocrText: "合成记录 \(day.timeIntervalSince1970)", textOrigin: .userInput))
        }
        let reviewed = state.captures[1]
        var summary = DailySummary(day: yesterday, content: "合成回顾", sourceCaptureIDs: [reviewed.id], todos: [], generationKind: .cloud)
        summary.items = [DailySummaryItem(section: .progress, title: "合成事项", detail: reviewed.ocrText, evidenceIDs: [reviewed.id],
            knowledge: DailyItemKnowledge(topic: "合成", kind: .matter, status: "completed", ownedByUser: true, quotes: [reviewed.ocrText]))]
        state.dailySummaries = [summary]
        let period = ReviewPeriod(start: twoDaysAgo, end: now)
        let gaps = PeriodReviewFromDaily.gaps(in: state, period: period, now: now)
        try expect(gaps.todayMissing && gaps.missingRecordedDays == [twoDaysAgo], "今天没有和过去缺失的天分开")
        try expect(gaps.allMissingDays == [twoDaysAgo, today], "补生成范围没有同时包含过去和今天")
        try expect(gaps.headline.contains("今天的记录还在进行中") && !gaps.headline.contains(Self.dayLabel(today)), "今天被当成普通缺失日展示")
        guard let trimmed = PeriodReviewFromDaily.excludingToday(period, now: now) else { throw Failure(errorDescription: "无法只回顾到昨天") }
        try expect(trimmed.start == twoDaysAgo && trimmed.end == today && trimmed.isValid, "只回顾到昨天的范围不正确")
        try expect(!PeriodReviewFromDaily.gaps(in: state, period: trimmed, now: now).todayMissing, "排除今天后仍提示今天缺失")
        try expect(PeriodReviewFromDaily.excludingToday(ReviewPeriod(start: today, end: now), now: now) == nil, "只含今天的范围被裁成空")

        // Morning review exists, then an afternoon capture arrives: todayStale triggers refresh until covered.
        let morningCap = state.captures[2]
        var morningReview = DailySummary(day: today, content: "上午回顾", sourceCaptureIDs: [morningCap.id], todos: [], generationKind: .cloud)
        morningReview.items = [DailySummaryItem(section: .progress, title: "上午事项", detail: morningCap.ocrText, evidenceIDs: [morningCap.id],
            knowledge: DailyItemKnowledge(topic: "合成上午", kind: .matter, status: "inProgress", ownedByUser: true, quotes: [morningCap.ocrText]))]
        state.dailySummaries.append(morningReview)
        let upToDateGaps = PeriodReviewFromDaily.gaps(in: state, period: period, now: now)
        try expect(!upToDateGaps.todayMissing && !upToDateGaps.todayStale && !upToDateGaps.allMissingDays.contains(today), "今日记录已全部纳入回顾时不应再提示补齐")

        let afternoonNow = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: now)!
        let afternoonCap = CaptureRecord(eventTemplate: .manualMoment, createdAt: today.addingTimeInterval(13 * 3_600), contentHash: UUID().uuidString,
                                         ocrText: "合成下午新增记录", textOrigin: .screenOCR)
        state.captures.append(afternoonCap)
        let afternoonPeriod = ReviewPeriod(start: twoDaysAgo, end: afternoonNow)
        let staleGaps = PeriodReviewFromDaily.gaps(in: state, period: afternoonPeriod, now: afternoonNow)
        try expect(!staleGaps.todayMissing && staleGaps.todayStale && staleGaps.todayUncoveredCount == 1, "今日下午新增未覆盖记录未被识别为 todayStale")
        try expect(staleGaps.todayNeedsUpdate && staleGaps.hasActionableGaps && staleGaps.allMissingDays == [twoDaysAgo, today], "待补齐列表未包含需要增量刷新的今天")
        try expect(staleGaps.headline.contains("1 条新记录未纳入回顾"), "标题未明确提示今天新增的未整理记录数：\(staleGaps.headline)")
    }
    static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "M/d"
        return formatter.string(from: date) + "未生成"
    }

    static func versionGroups() throws {
        let today = Calendar.current.startOfDay(for: .now)
        let week = ReviewPeriod(start: today.addingTimeInterval(-7 * 86_400), end: today)
        let other = ReviewPeriod(start: today.addingTimeInterval(-14 * 86_400), end: today.addingTimeInterval(-7 * 86_400))
        let learning = ReviewTemplate(kind: .learning)
        let first = report(learning, items: [item(.progress, "合成一")], period: week, createdAt: .now.addingTimeInterval(-300))
        let second = report(learning, items: [item(.progress, "合成二")], period: week, createdAt: .now)
        let personal = report(ReviewTemplate(kind: .personal), items: [item(.progress, "合成三")], period: week, createdAt: .now.addingTimeInterval(-100))
        let older = report(learning, items: [item(.progress, "合成四")], period: other, createdAt: .now.addingTimeInterval(-50))
        let groups = ReviewVersionGroup.groups([first, personal, older, second])
        try expect(groups.count == 3, "同一时间段同一模板的回顾没有合并成一项")
        guard let group = groups.first(where: { $0.versions.contains { $0.id == first.id } }) else { throw Failure(errorDescription: "版本分组丢失") }
        try expect(group.latest.id == second.id && group.versions.map(\.id) == [second.id, first.id], "版本没有按最新在前排列")
        try expect(group.number(of: first.id) == 1 && group.number(of: second.id) == 2, "版本编号不正确")
        try expect(groups.first?.latest.id == second.id, "列表没有按每组最新版本排序")
        var scoped = second; scoped.id = UUID(); scoped.scope = ReviewScope(topicIDs: ["合成主题"])
        try expect(scoped.versionKey != second.versionKey, "不同范围的回顾被当成同一份的版本")
    }
}
