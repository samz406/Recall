import Foundation
import RecallKit

enum ProductExperienceVerification {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(errorDescription: message) } }
    static func run() async throws {
        try contentBoundaries()
        try monthlyCalendar()
        try groupingAndClusters()
        try await mergeLifecycle()
        try await searchLifecycle()
        try await dailyVersionsAndActions()
        try legacyDecoding()
        try await realPhases()
    }
    static func note(_ title: String, date: Date = .now, category: ReviewCategory = .work) throws -> CaptureRecord {
        try ManualMatterNote(title: title, detail: title + "已完成具体方案并保存可核验的结果。", status: .completed,
            eventAt: date, reviewCategory: category).capture(recordedAt: date)
    }
    static func contentBoundaries() throws {
        let complete = ["发布发生于 19:48", "https://example.invalid/a:b", "请检查（时间 19:48）的回执", "设计文档.md §1.2：补充索引",
                        "完成 Atlas 账单校验后提交到仓库"]
        for text in complete {
            try expect(ReviewContentQuality.titleAndDetail(text) == [text], "时间、URL、路径或完整行动被冒号切断：" + text)
        }
        let split = ReviewContentQuality.titleAndDetail("账单导出：分页边界已验证")
        try expect(split == ["账单导出", "分页边界已验证"], "明确标题与说明没有分开")
        let subjects = ["Atlas 账单", "Nova 清单", "Orion 导出", "Cedar 登录", "Maple 索引"]
        for subject in subjects {
            for suffix in ["已经完成并通过验证", "尚未完成，需核对否定状态", "将于 19:48 继续", "已取消，不应再安排"] {
                let sentence = subject + suffix
                let repaired = DailySummaryItemParser.sanitized([DailySummaryItem(section: .progress, title: subject, detail: sentence)])[0]
                try expect(repaired.title == sentence && repaired.detail.isEmpty, "旧版前缀重复修复丢失了完整句意")
            }
        }
        let rejected = ["主线方法论与实际节奏高度同构", "心理熵升高", "记录密度说明偏好", "流水线已经稳定，可当固定工艺", "多次打开说明心理负担"]
        for title in rejected {
            for detail in ["来源只有重复截图", "来自文章观点", "来自助手提议", "没有独立记录"] {
                try expect(!ReviewContentQuality.usefulInsight(title: title, detail: detail), "无依据规律仍进入值得留意")
            }
        }
        let nonActions = ["发布日期：2026年9月18日", "提交记录：abc123", "网络异常，请检查网络后再试", "Leader 的目标不是完成任务", "下一步是修复"]
        for title in nonActions {
            for prefix in ["", "[聊天·角色未知] ", "[聊天·资料] "] {
                let record = CaptureRecord(eventTemplate: .manualMoment, contentHash: UUID().uuidString, ocrText: prefix + title)
                try expect(ReminderExtractor().candidates(from: [record]).isEmpty, "元数据或泛指残句成为待办：" + title)
            }
        }
        let item = DailySummaryItem(section: .progress, title: "**修复分页** [16]", detail: "保留 19:48 与 §1.2", evidenceIDs: [UUID()])
        let clean = DailySummaryItemParser.sanitized([item])[0]
        try expect(!clean.title.contains("**") && !clean.title.contains("[16]") && clean.detail.contains("19:48"), "标记清理破坏正文")
        try expect(ReviewContentQuality.usefulInsight(title: "账单重试条件发生变化", detail: "相同请求先失败，修复游标后通过；两条独立记录可核对。"), "具体变化被一并屏蔽")
        print("PASS: product content cases cover complete titles, duplication, metadata actions and unsupported insights")
    }
    static func monthlyCalendar() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2028, month: 3, day: 1, hour: 12))!
        let feb = ReviewPeriod.make(.previousMonth, at: now, calendar: calendar)
        try expect(feb.isValid && calendar.dateComponents([.day], from: feb.start, to: feb.end).day == 29, "完整月遗漏闰日")
        let current = ReviewPeriod.make(.currentMonth, at: now, calendar: calendar)
        try expect(current.start == feb.end && current.end == now && !feb.contains(current.start), "月份半开边界重复")
        var plan = ReviewSchedule(template: ReviewTemplate(kind: .personal)); plan.monthDay = 1
        plan.timeZoneIdentifier = "Asia/Shanghai"; plan.hour = 10; plan.periodKind = .previousMonth
        let next = plan.nextTrigger(after: now)!
        try expect(calendar.component(.month, from: next) == 4 && calendar.component(.day, from: next) == 1, "每月计划仍按星期计算")
        plan.nextRunAt = now.addingTimeInterval(-3600)
        try expect(plan.period(at: now) == feb, "月度计划范围不是完整上月")
        plan.monthDay = 31; try expect(!plan.isValid, "不可每月执行的日期未被拒绝")
    }
    static func groupingAndClusters() throws {
        let a = try note("Atlas 接口修复"), b = try note("Atlas 联调验证", date: .now.addingTimeInterval(-1))
        let files = MatterMemoryEngine().files(in: RecallState(captures: [a, b]))
        let group = MemoryTopicGroup(title: "Atlas 接口交付", memberIDs: files.map(\.id))
        let combined = MemoryTopicGroup.applying([group], to: files)
        try expect(combined.count == 1 && combined[0].evidenceIDs.count == 2 && combined[0].events.count == 2, "合并丢失来源或进展")
        try expect(MemoryTopicGroup.applying([], to: files).count == 2, "撤销无法恢复主题")
        var same = a; same.id = UUID(); same.createdAt = a.createdAt.addingTimeInterval(20)
        let clusters = TimelineRecordCluster.make([a, same, b], enabled: true)
        try expect(clusters.count == 2 && clusters.flatMap(\.records).count == 3, "折叠相同记录误删除原文")
        try expect(TimelineRecordCluster.make([a, same], enabled: false).count == 2, "关闭折叠后记录未恢复")
    }
    static func makeStore(_ state: RecallState) throws -> FileMemoryStore {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("Recall-product-" + UUID().uuidString))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: storage.stateURL)
        return try FileMemoryStore(storage: storage)
    }
    static func mergeLifecycle() async throws {
        let a = try note("Atlas 接口修复"), b = try note("Atlas 联调验证")
        let store = try makeStore(RecallState(captures: [a, b]))
        let original = await store.snapshot()
        let files = MatterMemoryEngine().files(in: original)
        let group = MemoryTopicGroup(title: "Atlas 接口交付", memberIDs: files.map(\.id))
        try await store.saveTopicGroup(group)
        let merged = await store.snapshot()
        try expect(MatterMemoryEngine().files(in: merged).count == 1 && merged.captures.map(\.ocrText) == original.captures.map(\.ocrText), "持久化合并改写原文")
        let cache = MemoryWorkspaceCache(), first = try await cache.prepare(in: original), second = try await cache.prepare(in: merged)
        try expect(first.revision != second.revision && second.matters.count == 1, "合并没有失效工作区缓存")
        try await store.undoTopicGroup(group.id)
        let undone = await store.snapshot()
        try expect(undone.topicGroups.isEmpty && MatterMemoryEngine().files(in: undone).count == 2, "撤销合并没有持久化")
        let life = try note("周末植物记录", category: .personal)
        let mixedStore = try makeStore(RecallState(captures: [a, life]))
        let mixed = await mixedStore.snapshot(), ids = MatterMemoryEngine().files(in: mixed).map(\.id)
        do { try await mixedStore.saveTopicGroup(.init(title: "混合主题", memberIDs: ids)); throw Failure(errorDescription: "工作与生活被合并进入工作模板") }
        catch WeeklyReviewError.noWorkScope { }
    }
    static func searchLifecycle() async throws {
        let source = try note("Atlas 账单验收")
        var state = RecallState(captures: [source])
        state.dailySummaries = [DailySummary(day: source.createdAt, content: "", sourceCaptureIDs: [source.id], todos: [], generationKind: .localFallback,
            items: [.init(section: .progress, title: "Atlas 账单验收", evidenceIDs: [source.id])])]
        state.reminders = [.init(title: "Atlas 账单复核", detail: "具体事项", sourceCaptureIDs: [source.id], confidence: 1)]
        let report = try await WeeklyReviewEngine().generate(in: state, period: ReviewPeriod.make(.recentSeven), template: ReviewTemplate(kind: .personal))
        state.weeklyReports = [report]
        let files = MatterMemoryEngine().files(in: state), index = GlobalMemorySearch(state: state, matters: files)
        let result = index.search("Atlas 账单")
        try expect(Set(result.map(\.kind)).isSuperset(of: ["原始记录", "记忆主题", "每日回顾", "周期回顾", "提醒"]), "全局搜索缺少类型")
        try expect(index.search("Atlas", start: Date.now.addingTimeInterval(100)).isEmpty && index.search("Atlas", app: "不存在的应用").isEmpty, "日期或来源过滤失效")
        state.captures = []
        let deleted = GlobalMemorySearch(state: state, matters: files)
        try expect(deleted.search("Atlas").isEmpty, "已删除来源的派生结果仍能搜索")
    }
    static func dailyVersionsAndActions() async throws {
        let source = try note("Atlas 账单验收"), actionID = UUID()
        let action = DailySummaryTodo(id: actionID, title: "复核 Atlas 账单", detail: "核对具体验收结果", sourceCaptureIDs: [source.id], priority: .normal)
        let old = DailySummary(day: source.createdAt, content: "", sourceCaptureIDs: [source.id], todos: [action], generationKind: .localFallback,
            items: [.init(section: .actions, title: action.title, evidenceIDs: [source.id], actionCandidateID: actionID)])
        let store = try makeStore(RecallState(captures: [source], dailySummaries: [old]))
        var newer = old; newer.id = UUID(); newer.createdAt = Date.now.addingTimeInterval(1)
        let consolidation = PersonalIntelligenceEngine().consolidate(day: source.createdAt, records: [source])
        try await store.commitDailySummary(newer, consolidation: consolidation)
        var snapshot = await store.snapshot()
        try expect(snapshot.dailySummaries[0].versions?.first?.id == old.id, "重新生成丢失旧版本")
        let reminder = ReminderCandidate(id: actionID, title: action.title, detail: action.detail, sourceCaptureIDs: [source.id], confidence: 1, status: .completed)
        try await store.updateReminder(reminder, learningProfile: ReminderLearningProfile())
        snapshot = await store.snapshot()
        try expect(snapshot.dailySummaries[0].todos[0].status == .completed, "完成提醒后回顾仍计作待办")
    }
    static func legacyDecoding() throws {
        let state = try JSONDecoder().decode(RecallState.self, from: Data("{}".utf8))
        try expect(state.topicGroups.isEmpty, "旧存档缺新字段无法读取")
        let schedule = ReviewSchedule(template: ReviewTemplate(kind: .personal))
        let decoded = try JSONDecoder().decode(ReviewSchedule.self, from: JSONEncoder().encode(schedule))
        try expect(decoded.monthDay == nil && decoded.isValid, "旧每周计划失效")
    }
    actor Phases { var values: [String] = []; func add(_ value: String) { values.append(value) } }
    static func realPhases() async throws {
        let source = try note("Atlas 账单验收"), phases = Phases()
        _ = try await WeeklyReviewEngine().generate(in: RecallState(captures: [source]), period: ReviewPeriod.make(.recentSeven), template: ReviewTemplate(kind: .personal),
            onPhase: { await phases.add($0) })
        let values = await phases.values
        try expect(values == ["整理主题变化", "核验来源"], "本地生成伪装为已经调用模型")
    }
}
