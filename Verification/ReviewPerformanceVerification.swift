import Foundation
import RecallKit

enum ReviewPerformanceVerification {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    static func run() async throws {
        try largeRangeIndex()
        try categoryAndDateParity()
        try await cacheLifecycle()
    }

    private static func largeRangeIndex() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let start = now.addingTimeInterval(-7 * 86_400)
        let period = ReviewPeriod(start: start, end: now, timeZoneIdentifier: "UTC")
        // Many distinct topics and sources: duplicates-only fixtures miss the quadratic path.
        let sources = (0..<6351).map { i in
            CaptureRecord(eventTemplate: .manualMoment, createdAt: start.addingTimeInterval(Double(i % 9) * 86_400),
                sourceBundleIdentifier: "test.review-index", contentHash: "synthetic-\(i)",
                ocrText: i % 5 == 0 ? " \n" : "合成测试记录 \(i)：完整的正文保存在来源中，不应被范围控件反复读取。")
        }
        let files = (0..<1319).map { i in
            let records = Array(sources[(i * 4)..<(i * 4 + 4)])
            return MatterFile(id: "reference:test-\(i)", title: "测试主题 \(i)", events: records.map { source in
                MatterEvent(id: UUID(), title: "测试主题 \(i)", detail: source.ocrText,
                    recordedAt: source.createdAt, status: .explored, evidenceIDs: records.map(\.id))
            })
        }
        let state = RecallState(captures: sources)
        let clock = ContinuousClock(), begin = clock.now
        let index = ReviewWorkspaceIndex(state: state, topics: files)
        let preparedAt = clock.now
        let expected = ReviewRecordCoverage(state: state, period: period)
        let topicCount = files.filter { $0.events.contains { period.contains($0.date) } }.count
        let queryStart = clock.now
        for _ in 0..<200 {
            let preview = index.preview(in: period, kind: .personal, scope: ReviewScope())
            try expect(preview.topicCount == topicCount && preview.eligibleTopicCount == topicCount,
                "大量主题的预览漏计，或把个人回顾限制成工作分类")
            try expect(preview.coverage.totalRecords == 6351 && preview.coverage.periodRecords == expected.periodRecords
                && preview.coverage.textRecords == expected.textRecords, "范围索引丢失记录或半开日期边界不一致")
        }
        print("PERF: 6351 sources / 1319 topics; index \(begin.duration(to: preparedAt)); 200 range previews \(queryStart.duration(to: clock.now))")
        let selected = ReviewScope(topicIDs: Set(files.prefix(8).map(\.id)))
        try expect(index.preview(in: period, kind: .work, scope: selected).eligibleTopicCount == 8,
            "工作回顾未保留用户明确选择的未分类主题")
        try expect(index.preview(in: period, kind: .work, scope: ReviewScope()).eligibleTopicCount == 0,
            "未分类主题被自动混入工作周报")
    }

    private static func categoryAndDateParity() throws {
        let now = Date.now, day = now.addingTimeInterval(-2 * 86_400)
        func note(_ title: String, _ category: ReviewCategory, at date: Date) throws -> CaptureRecord {
            try ManualMatterNote(title: title, detail: "保存了可核对的具体过程。", status: .explored,
                eventAt: date, reviewCategory: category).capture(recordedAt: date)
        }
        let first = try note("Atlas 分类变化", .personal, at: day)
        let latest = try note("Atlas 分类变化", .work, at: day.addingTimeInterval(1))
        let learning = try note("木刻练习记录", .learning, at: day)
        let excluded = try note("不参与回顾记录", .work, at: day)
        var state = RecallState(captures: [first, latest, learning, excluded])
        state.matterCorrections = [MatterCorrection(evidenceIDs: [excluded.id], kind: .notMine),
            MatterCorrection(evidenceIDs: [learning.id], kind: .eventDate, eventAt: now.addingTimeInterval(-20 * 86_400))]
        let period = ReviewPeriod.make(.recentSeven, at: now)
        let engine = WeeklyReviewEngine(), topics = engine.topics(in: state)
        let index = ReviewWorkspaceIndex(state: state, topics: topics)
        let workID = topics.first { $0.evidenceIDs.contains(first.id) }!.id
        try expect(index.topics.first { $0.id == workID }?.category == .work,
            "分类索引没有采用最新手动记录的有效分类")
        for kind in ReviewTemplateKind.allCases {
            let items = try engine.items(in: state, period: period, template: ReviewTemplate(kind: kind), scope: ReviewScope())
            try expect(index.preview(in: period, kind: kind, scope: ReviewScope()).eligibleTopicCount == items.count,
                "预览与实际生成的日期、分类或筛选范围不同")
        }
        let legacy = ReviewRecordCoverage(state: state, period: period), current = index.coverage(in: period)
        try expect(current.totalRecords == legacy.totalRecords && current.periodRecords == legacy.periodRecords
            && current.textRecords == legacy.textRecords && current.latestRecordAt == legacy.latestRecordAt,
            "范围索引忽略了归属或发生时间更正")
        state.reviewCategories[workID] = .unclassified
        let overridden = ReviewWorkspaceIndex(state: state, topics: topics)
        try expect(overridden.topics.first { $0.id == workID }?.category == .unclassified,
            "用户手动取消分类后预览仍采用原分类")
    }

    private static func cacheLifecycle() async throws {
        let day = Date.now.addingTimeInterval(-86_400)
        let note = try ManualMatterNote(title: "Atlas 分页核对", detail: "核对分页边界后保存对照样本。",
            status: .explored, eventAt: day, reviewCategory: .work).capture(recordedAt: day)
        var state = RecallState(captures: [note])
        let cache = MemoryWorkspaceCache()
        let first = try await cache.prepare(in: state)
        try expect(first.review.topics.count == 1 && first.sources[note.id] != nil, "后台投影没有准备完整范围和来源")
        state.messages.append(ConversationMessage(role: .user, content: "与归档无关的聊天刷新"))
        state.reviewTemplates.append(ReviewTemplate(kind: .personal, id: "test-format"))
        let reused = try await cache.prepare(in: state)
        try expect(first.revision == reused.revision, "无关聊天或模板刷新重复解析了全部归档")
        let topicID = first.review.topics[0].id
        state.reviewCategories[topicID] = .personal
        let category = try await cache.prepare(in: state)
        try expect(category.revision != reused.revision && category.review.topics[0].category == .personal,
            "更改分类没有使后台投影失效")
        state.captures[0].manualMatter?.detail = "更新后保存了新的边界对照结果。"
        state.captures[0].ocrText = "更新后的原始文字，数量、日期与内容哈希保持相同。"
        let edited = try await cache.prepare(in: state)
        try expect(edited.revision != category.revision && edited.sources[note.id]?.ocrText == state.captures[0].ocrText,
            "同数量、同日期、同哈希的正文更正复用了旧缓存")
        state.matterCorrections = [MatterCorrection(evidenceIDs: [note.id], kind: .notMine)]
        let corrected = try await cache.prepare(in: state)
        try expect(corrected.review.topics.isEmpty && corrected.review.coverage(in: .make(.recentSeven)).totalRecords == 0,
            "归属更正后仍显示旧主题或覆盖数量")
        state.captures.removeAll(); state.matterCorrections = []
        let deleted = try await cache.prepare(in: state)
        try expect(deleted.sources.isEmpty && deleted.matters.isEmpty && deleted.summary.records == 0,
            "删除后后台缓存残留来源或统计")
        let deletedState = state
        state.captures = [note]
        let changed = state
        let cancelled = await withTaskGroup(of: Bool.self) { group in
            group.cancelAll()
            group.addTask {
                do { _ = try await cache.prepare(in: changed); return false }
                catch is CancellationError { return true }
                catch { return false }
            }
            return await group.next() ?? false
        }
        try expect(cancelled, "取消的旧构建覆盖了当前投影")
        let stillDeleted = try await cache.prepare(in: deletedState)
        try expect(stillDeleted.revision == deleted.revision, "取消任务写入了不完整的缓存")
        let restored = try await cache.prepare(in: changed)
        try expect(restored.revision != deleted.revision && restored.sources[note.id] != nil,
            "恢复记录后没有重建范围与来源索引")
        var hidden = changed; hidden.privacy.excludedBundleIdentifiers.insert("im.recall.app")
        let excluded = try await cache.prepare(in: hidden)
        try expect(excluded.revision != restored.revision && excluded.review.coverage(in: .make(.recentSeven)).totalRecords == 0,
            "应用排除设置未使范围统计失效")
    }
}
