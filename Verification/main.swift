import Foundation
import RecallKit

@main
struct RecallVerifier {
    static func main() async {
        do {
            try verifyDefaultEventTemplates()
            try await verifyEventRuleMigration()
            try verifyPrivacy()
            try verifySearch()
            try verifyTimelineDayGrouping()
            try verifyTimelineDayFiltering()
            try verifyReminders()
            try verifyReminderPrecision()
            try await verifyReminderSchedulePersistence()
            try await verifyDailySummaryGeneration()
            try await verifyDailySummaryPersistenceAndDeletion()
            try verifyPersonalIntelligenceConsolidation()
            try verifyConcreteDailySummarySubjects()
            try verifyInsightFeedbackLearning()
            try await verifyIntelligencePersistenceAndFTS()
            try verifyBackwardCompatibleIntelligenceState()
            try await verifyNotificationHostGuard()
            try await verifyCapturePipeline()
            try verifyConversationContextCompression()
            try await verifyPersistence()
            try await verifyCustomModelConfigurationPersistence()
            try await verifyMiniMaxAuthenticationHeaders()
            try await verifyTodayQuestionUsesTimeline()
            try await verifyLocalAnswer()
            if CommandLine.arguments.contains("--live-anthropic") {
                try await verifyLiveAnthropicCompatibility()
                print("PASS: RecallVerifier completed 25 checks, including live Anthropic compatibility.")
            } else {
                print("PASS: RecallVerifier completed 24 integration checks.")
            }
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func verifyDefaultEventTemplates() throws {
        let rules = EventRule.defaults()
        try expect(rules.count == 9, "应提供 9 个事件模板")
        try expect(Set(rules.map(\.template)) == Set(CaptureEventTemplate.allCases), "事件模板集合不完整")
        try expect(rules.contains(where: { $0.template == .manualMoment && $0.isEnabled }), "手动记录此刻应默认启用")
        try expect(rules.contains(where: { $0.template == .enterKeyTrigger && !$0.isEnabled }), "Enter 键触发记录必须默认关闭")
    }

    private static func verifyEventRuleMigration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let legacyRules = EventRule.defaults().filter { $0.template != .enterKeyTrigger }
        let legacyState = RecallState(rules: legacyRules)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacyState).write(to: storage.stateURL, options: .atomic)

        let store = try FileMemoryStore(storage: storage)
        let migratedState = await store.snapshot()
        try expect(migratedState.rules.contains(where: { $0.template == .enterKeyTrigger && !$0.isEnabled }), "旧状态没有补入默认关闭的 Enter 键规则")
    }

    private static func verifyPrivacy() throws {
        let engine = PrivacyEngine()
        let text = "alice@example.com，卡号 4111 1111 1111 1111，密码: super-secret"
        let redacted = engine.redact(text)
        try expect(!redacted.contains("alice@example.com"), "邮箱未被脱敏")
        try expect(!redacted.contains("4111 1111 1111 1111"), "卡号未被脱敏")
        try expect(!redacted.contains("super-secret"), "密码未被脱敏")
        let decision = engine.decision(for: "com.example.private", settings: PrivacySettings(excludedBundleIdentifiers: ["com.example.private"]))
        try expect(!decision.mayCapture, "排除应用仍被允许采集")
    }

    private static func verifySearch() throws {
        let matching = makeCapture(text: "和产品团队讨论 Recall 的 OCR 质量与会议摘要", app: "Notes")
        let unrelated = makeCapture(text: "今天午餐吃面", app: "Messages")
        let results = MemorySearchEngine().search(MemorySearchQuery(text: "OCR 会议摘要"), in: [unrelated, matching])
        try expect(results.first?.capture.id == matching.id, "搜索没有优先返回相关记录")
        try expect(results.first?.matchedTerms.contains("ocr") == true, "搜索未报告匹配关键词")
    }

    private static func verifyTimelineDayGrouping() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!

        let previousNight = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 23, minute: 58))!
        let earlyMorning = calendar.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 0, minute: 2))!
        let laterMorning = calendar.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 10, minute: 15))!
        let older = makeCapture(text: "前一天晚间记录", app: "Notes", createdAt: previousNight)
        let early = makeCapture(text: "午夜后记录", app: "Notes", createdAt: earlyMorning)
        let later = makeCapture(text: "当天上午记录", app: "Notes", createdAt: laterMorning)

        let groups = TimelineGrouping.dayGroups(for: [early, older, later], calendar: calendar)
        try expect(groups.count == 2, "时间线没有按本地自然日分组")
        try expect(calendar.isDate(groups[0].day, inSameDayAs: laterMorning), "最新日期组排序错误")
        try expect(groups[0].captures.map(\.id) == [later.id, early.id], "同一天内的记录没有按从新到旧排序")
        try expect(calendar.isDate(groups[1].day, inSameDayAs: previousNight), "午夜前记录被归入了错误日期")
    }

    private static func verifyTimelineDayFiltering() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!

        let selectedDay = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 12))!
        let startOfDay = calendar.startOfDay(for: selectedDay)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        let first = makeCapture(text: "当天第一条", app: "Notes", createdAt: startOfDay)
        let last = makeCapture(text: "当天最后一条", app: "Xcode", createdAt: endOfDay.addingTimeInterval(-1))
        let previous = makeCapture(text: "前一天记录", app: "Mail", createdAt: startOfDay.addingTimeInterval(-1))
        let next = makeCapture(text: "次日记录", app: "Safari", createdAt: endOfDay)

        let filtered = TimelineGrouping.captures(on: selectedDay, from: [previous, first, next, last], calendar: calendar)
        try expect(filtered.map(\.id) == [last.id, first.id], "时间线日期筛选没有使用本地自然日边界")
    }

    private static func verifyReminders() throws {
        let capture = makeCapture(text: "待办：明天回复客户关于报价的邮件", app: "Mail")
        let extractor = ReminderExtractor()
        let candidates = extractor.candidates(from: [capture], existing: [])
        try expect(candidates.count == 1, "应从待办文本创建一个提醒候选")
        try expect(candidates.first?.dueAt != nil, "未推断出明天的提醒时间")
        try expect(extractor.candidates(from: [capture], existing: candidates).isEmpty, "提醒候选去重失败")
    }

    private static func verifyReminderPrecision() throws {
        let calendar = Calendar.current
        let base = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 11))!
        let first = makeCapture(text: "待办：明天下午3点提交社会心理学调研报告", app: "Notes", createdAt: base)
        let duplicate = makeCapture(text: "任务：明天下午3点提交社会心理学调研报告", app: "Messages", createdAt: base.addingTimeInterval(60))
        let deadlineOnly = makeCapture(text: "【服务截止】", app: "Messages", createdAt: base)
        let uncertainQuestion = makeCapture(text: "我记得券兑换码也是券过期的时候推送过期是吧", app: "Messages", createdAt: base)
        let codeNoise = makeCapture(text: "//todo test log", app: "IntelliJ IDEA", createdAt: base)
        let completed = makeCapture(text: "已完成：明天提交版本发布说明", app: "Notes", createdAt: base)

        let candidates = ReminderExtractor().candidates(
            from: [first, duplicate, deadlineOnly, uncertainQuestion, codeNoise, completed],
            existing: []
        )
        try expect(candidates.count == 1, "提醒精度过滤未排除疑问句、完成态、截止标签或代码噪声")
        try expect(candidates[0].title == "明天下午3点提交社会心理学调研报告", "提醒标题没有提炼为明确行动")
        try expect(candidates[0].sourceCaptureIDs.count == 2, "重复记录没有合并为同一提醒候选")
        if let dueAt = candidates[0].dueAt {
            let components = calendar.dateComponents([.day, .hour, .minute], from: dueAt)
            try expect(components.day == 9 && components.hour == 15 && components.minute == 0, "提醒时间没有正确识别明天下午3点")
        } else {
            throw VerificationError.failed("明确时间线索没有生成建议提醒时间")
        }

        let report = makeCapture(
            text: "写一篇介绍《社会心理学》的调研报告，需要包含主要内容和产品设计应用",
            app: "Chrome",
            createdAt: base
        )
        let reportCandidate = ReminderExtractor().candidates(from: [report], existing: []).first
        try expect(reportCandidate?.title == "写一篇介绍《社会心理学》的调研报告", "长句提醒没有提炼行动主干")
    }

    private static func verifyReminderSchedulePersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let candidate = ReminderCandidate(title: "在用户指定时间提醒", detail: "验证自定义提醒时间。", confidence: 0.8)
        try await store.replaceReminders([candidate])

        let selectedDate = Date(timeIntervalSince1970: 1_800_000_000)
        var scheduled = candidate
        scheduled.dueAt = selectedDate
        scheduled.status = .scheduled
        try await store.updateReminder(scheduled)

        let reloaded = try FileMemoryStore(storage: storage)
        let restored = await reloaded.snapshot().reminders.first
        try expect(restored?.status.rawValue == ReminderStatus.scheduled.rawValue, "用户确认的提醒状态没有保存")
        try expect(abs((restored?.dueAt?.timeIntervalSince1970 ?? 0) - selectedDate.timeIntervalSince1970) < 0.01, "用户选择的提醒时间没有保存")

        let proposed = ReminderCandidate(title: "待批量忽略", detail: "验证批量忽略只影响候选提醒。", confidence: 0.7)
        try await reloaded.updateReminder(proposed)
        let dismissedCount = try await reloaded.dismissAllProposedReminders()
        let afterDismissal = await reloaded.snapshot().reminders
        try expect(dismissedCount == 1, "批量忽略应返回实际更新的待确认提醒数量")
        try expect(afterDismissal.first(where: { $0.id == proposed.id })?.status == .dismissed, "待确认提醒没有被批量忽略")
        try expect(afterDismissal.first(where: { $0.id == scheduled.id })?.status == .scheduled, "批量忽略不应影响已安排提醒")
    }

    private static func verifyDailySummaryGeneration() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let targetDay = calendar.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: 12))!
        let source = makeCapture(
            text: "待办：明天回复客户关于报价的邮件。今天完成了每日总结原型。",
            app: "Notes",
            createdAt: targetDay
        )
        var unrelated = makeCapture(text: "前一天记录", app: "Notes", createdAt: targetDay.addingTimeInterval(-86_400))
        unrelated.eventTemplate = .dailyReview

        let recentSummary = DailySummary(
            day: targetDay.addingTimeInterval(-6 * 86_400),
            content: "近期待跟进客户报价",
            sourceCaptureIDs: [],
            todos: [DailySummaryTodo(title: "跟进客户报价", detail: "历史总结中的待办", priority: .high)],
            generationKind: .localFallback
        )
        let expiredSummary = DailySummary(
            day: targetDay.addingTimeInterval(-15 * 86_400),
            content: "不应纳入十四天窗口",
            sourceCaptureIDs: [],
            todos: [DailySummaryTodo(title: "过期历史待办", detail: "窗口外", priority: .normal)],
            generationKind: .localFallback
        )
        let generator = DailySummaryGenerator()
        let selectedRecent = generator.recentSummaries(for: targetDay, from: [recentSummary, expiredSummary], calendar: calendar)
        try expect(selectedRecent.map(\.id) == [recentSummary.id], "跨周期总结应只选取目标日前十四天内的已保存总结")

        let generation = try await generator.generate(
            day: targetDay,
            from: [source, unrelated],
            previousSummaries: [recentSummary, expiredSummary],
            responder: nil,
            calendar: calendar
        )
        try expect(generation.generationKind == .localFallback, "未配置模型时应生成本地回退摘要")
        try expect(generation.sourceCaptureIDs == [source.id], "每日总结混入了非目标日期或旧回顾记录")
        try expect(generation.todos.count == 1, "每日总结没有提取待办事项")
        try expect(generation.todos.first?.priority == .high, "带有建议时间的待办应被标为优先处理")
        try expect(generation.content.contains("个人简报"), "本地每日总结缺少可读摘要正文")
        try expect(!generation.briefing.headline.isEmpty && !generation.briefing.progress.isEmpty, "每日总结没有形成结构化工作主线")
        try expect(generation.content.contains("近 14 天提醒与建议"), "每日总结缺少跨周期提醒区块")
        try expect(generation.content.contains("跟进客户报价"), "近十四天已保存总结中的待办没有被聚合")
        try expect(!generation.content.contains("过期历史待办"), "十四天窗口外的历史总结不应参与聚合")
    }

    private static func verifyDailySummaryPersistenceAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let settings = DailySummarySettings(isEnabled: true, hour: 0, minute: 8)
        let capture = makeCapture(text: "待办：测试每日总结删除联动", app: "Verifier")
        let summary = DailySummary(
            day: capture.createdAt,
            content: "测试每日总结",
            sourceCaptureIDs: [capture.id],
            todos: [DailySummaryTodo(title: "测试待办", detail: "测试来源删除", sourceCaptureIDs: [capture.id], priority: .high)],
            generationKind: .localFallback
        )
        try await store.updateDailySummarySettings(settings)
        try await store.addCapture(capture)
        try await store.upsertDailySummary(summary)

        let restored = await store.snapshot()
        try expect(restored.dailySummarySettings == settings, "每日总结开关或执行时间没有保存")
        try expect(restored.dailySummaries.count == 1, "每日总结没有保存")
        _ = try await store.deleteCapture(id: capture.id)
        let afterDeletion = await store.snapshot()
        try expect(afterDeletion.dailySummaries.isEmpty, "删除来源记录后应清除包含该内容的每日总结")
    }

    private static func verifyPersonalIntelligenceConsolidation() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 9))!
        var first = makeCapture(text: "项目：Recall 正在重构每日简报。", app: "Xcode", createdAt: day)
        first.windowTitle = "Recall - Xcode"
        var second = makeCapture(text: "项目：Recall 已完成 Episode 聚类，测试通过。下一步：接入反馈。", app: "Xcode", createdAt: day.addingTimeInterval(20 * 60))
        second.windowTitle = "Recall - Xcode"
        var preference = makeCapture(text: "我喜欢高密度、少打扰的个人建议。", app: "Notes", createdAt: day.addingTimeInterval(90 * 60))
        preference.windowTitle = "个人工作约定 - Notes"

        let engine = PersonalIntelligenceEngine()
        let result = engine.consolidate(day: day, records: [first, second, preference], calendar: calendar)
        try expect(result.episodes.count == 2, "相邻的同项目记录没有合并为工作片段")
        try expect(result.episodes.first(where: { $0.projectName == "Recall" })?.status == .completed, "工作片段没有识别已完成结果")
        try expect(result.projectStates.contains(where: { $0.projectKey.contains("recall") }), "工作片段没有更新项目状态")
        try expect(result.memories.contains(where: { $0.kind == .preference && $0.status == .proposed }), "明确偏好没有形成待确认用户记忆")
        try expect(result.briefing.progress.contains(where: { $0.detail.contains("测试通过") }), "结构化简报没有保留可验证进展")

        let manyRecords = (0..<10).map { index in
            makeCapture(text: index == 9 ? "项目：Recall 当天最后完成发布检查。" : "项目：Recall 记录 \(index)", app: "Xcode", createdAt: day.addingTimeInterval(Double(index) * 60))
        }
        let selected = DailySummaryGenerator(maxRecords: 6).sourceRecords(for: day, from: manyRecords, calendar: calendar)
        try expect(selected.contains(where: { $0.ocrText.contains("最后完成发布检查") }), "重要性采样仍然丢失当天后半段记录")
    }

    private static func verifyConcreteDailySummarySubjects() throws {
        let day = Date(timeIntervalSince1970: 1_788_854_400)
        var first = makeCapture(text: "今天推进退款订单接口修复，已定位重复退款校验缺失。", app: "企业微信", createdAt: day)
        first.windowTitle = "企业微信"
        var second = makeCapture(text: "待办：明天补充退款幂等测试并提交 PR。", app: "企业微信", createdAt: day.addingTimeInterval(70 * 60))
        second.windowTitle = "企业微信"
        var noise = makeCapture(text: "待办", app: "localmcp", createdAt: day.addingTimeInterval(140 * 60))
        noise.windowTitle = "localmcp"

        let result = PersonalIntelligenceEngine().consolidate(day: day, records: [first, second, noise])
        let conclusionText = ([result.briefing.headline] +
            result.briefing.progress.map(\.title) +
            result.briefing.openLoops.map(\.title) +
            result.insights.map(\.title)).joined(separator: "\n")
        try expect(conclusionText.contains("退款订单接口修复"), "每日简报没有提取到具体事项")
        try expect(!conclusionText.contains("企业微信") && !conclusionText.contains("localmcp"), "应用或工具名仍被当成总结事项")
        try expect(!result.projectStates.contains(where: { ["企业微信", "localmcp"].contains($0.displayName) }), "应用或工具名仍被沉淀为长期项目")
        try expect(!result.briefing.openLoops.contains(where: { $0.title == "未闭环 · 企业微信" }), "未闭环标题仍在复用来源应用")

        let unfinished = makeCapture(text: "待完成账单导出测试。", app: "Xcode", createdAt: day)
        try expect(PersonalIntelligenceEngine().buildEpisodes(day: day, records: [unfinished]).first?.status != .completed, "带否定语义的‘待完成’被误判为已完成")
    }

    private static func verifyInsightFeedbackLearning() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let records = (0..<4).map { index in
            makeCapture(
                text: "项目：Project\(index) 正在处理不同任务。",
                app: "Editor",
                createdAt: day.addingTimeInterval(Double(index) * 70 * 60)
            )
        }
        let engine = PersonalIntelligenceEngine()
        let initial = engine.consolidate(day: day, records: records)
        try expect(initial.insights.contains(where: { $0.kind == .contextSwitching }), "多项目切换没有形成行为洞察")
        let rejected = [
            InsightFeedback(insightID: UUID(), insightKind: .contextSwitching, rating: .inaccurate),
            InsightFeedback(insightID: UUID(), insightKind: .contextSwitching, rating: .dismissed)
        ]
        let learned = engine.consolidate(day: day, records: records, feedback: rejected)
        try expect(!learned.insights.contains(where: { $0.kind == .contextSwitching }), "连续否定后仍然推送相同类型洞察")

        var historicalEpisodes: [WorkEpisode] = []
        for offset in 1...3 {
            let historicalDay = day.addingTimeInterval(Double(-offset) * 86_400)
            historicalEpisodes += engine.buildEpisodes(
                day: historicalDay,
                records: [makeCapture(text: "项目：Recall 推进例行工作", app: "Xcode", createdAt: historicalDay)]
            )
        }
        let routineResult = engine.consolidate(day: day, records: [makeCapture(text: "项目：Recall 继续推进", app: "Xcode", createdAt: day)], existingEpisodes: historicalEpisodes)
        try expect(routineResult.routines.contains(where: { $0.status == .proposed && $0.evidenceCount >= 3 }), "重复工作没有形成待确认个人规则")
    }

    private static func verifyIntelligencePersistenceAndFTS() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let indexAvailable = await store.isIntelligenceIndexAvailable()
        try expect(indexAvailable, "SQLite/FTS5 本地智能索引没有启用")
        let capture = makeCapture(text: "RecallUniqueFTSTerm 完成智能索引迁移", app: "Verifier")
        try await store.addCapture(capture)
        let indexed = await store.indexedCaptureIDs(matching: "RecallUniqueFTSTerm")
        try expect(indexed == [capture.id], "FTS5 没有检索到已持久化的记录")

        let consolidation = PersonalIntelligenceEngine().consolidate(day: capture.createdAt, records: [capture])
        let summary = DailySummary(
            day: capture.createdAt,
            content: "结构化持久化测试",
            sourceCaptureIDs: [capture.id],
            todos: [],
            generationKind: .localFallback,
            briefing: consolidation.briefing
        )
        try await store.commitDailySummary(summary, consolidation: consolidation)
        guard let insight = consolidation.insights.first else { throw VerificationError.failed("智能整理没有生成可反馈洞察") }
        try await store.reviewInsight(id: insight.id, rating: .accurate)
        if let memory = consolidation.memories.first {
            try await store.reviewUserMemory(id: memory.id, status: .confirmed)
        }
        let reloaded = try FileMemoryStore(storage: storage)
        let restored = await reloaded.snapshot()
        try expect(!restored.episodes.isEmpty && !restored.projects.isEmpty, "工作片段或项目状态重新加载后丢失")
        try expect(restored.dailySummaries.first?.briefing != nil, "结构化简报重新加载后丢失")
        try expect(restored.insightFeedback.first?.rating == .accurate, "洞察反馈重新加载后丢失")
    }

    private static func verifyBackwardCompatibleIntelligenceState() throws {
        let legacy = """
        {"rules":[],"captures":[],"messages":[],"reminders":[],"dailySummaries":[],"dailySummarySettings":{"isEnabled":false,"hour":0,"minute":5},"privacy":{"excludedBundleIdentifiers":[],"cloudUseEnabled":false,"retainScreenshots":true,"screenCapturePaused":false},"llmConfiguration":{"provider":"localOnly","baseURLString":"","model":"","apiKey":"","anthropicVersion":"2023-06-01","maxOutputTokens":1000},"conversationSummaryCoveredMessageCount":0}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(RecallState.self, from: Data(legacy.utf8))
        try expect(state.episodes.isEmpty && state.userMemories.isEmpty && state.learnedRoutines.isEmpty, "旧状态迁移没有为智能数据提供安全默认值")
        try expect(state.dailySummarySettings.notifyWhenReady == nil, "旧状态不应自动开启总结通知")
    }

    @MainActor
    private static func verifyNotificationHostGuard() async throws {
        do {
            _ = try await LocalNotificationScheduler().requestAuthorization()
            throw VerificationError.failed("命令行验证器不应直接触发系统通知授权")
        } catch ReminderNotificationError.hostApplicationRequired {
            // Expected: a raw SwiftPM executable is not a notification-capable .app host.
        }
    }

    @MainActor
    private static func verifyCapturePipeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let pipeline = CapturePipeline(
            store: store,
            storage: storage,
            screenCapturer: MockCapturer(),
            recognizer: MockRecognizer()
        )
        let rule = EventRule(template: .manualMoment, isEnabled: true, scope: .selectedWindow)
        let capture = try await pipeline.record(using: rule)
        let snapshot = await store.snapshot()

        try expect(snapshot.captures.count == 1, "记录管线没有写入本地记忆")
        try expect(capture.isRedacted, "记录管线未对 OCR 内容执行脱敏")
        try expect(capture.imageRelativePath != nil, "记录管线未保存用户允许保留的截图")
        do {
            _ = try await pipeline.record(using: rule)
            throw VerificationError.failed("记录管线未阻止短时间内的重复内容")
        } catch CapturePipelineError.duplicateCapture {
            // Expected.
        }

        let enterRule = EventRule(template: .enterKeyTrigger, isEnabled: true, scope: .textOnly)
        let enterCapture = try await pipeline.record(using: enterRule, userText: "通过外部应用全局 Enter 触发保存的内容")
        let afterEnterCapture = await store.snapshot()
        try expect(enterCapture.eventTemplate == .enterKeyTrigger, "全局 Enter 触发没有写入对应事件模板")
        try expect(enterCapture.imageRelativePath == nil, "全局 Enter 触发记录不应依赖截图")
        try expect(afterEnterCapture.captures.count == 2, "全局 Enter 触发没有写入时间线")
    }

    private static func verifyConversationContextCompression() throws {
        let history = (0..<12).flatMap { index in
            [
                ConversationMessage(role: .user, content: "第 \(index) 轮用户问题：请记录这条内容。"),
                ConversationMessage(role: .assistant, content: "第 \(index) 轮 Recall 回答：已根据本地来源整理。")
            ]
        }
        let manager = ConversationContextManager(maxRecentMessages: 8, maxSummaryCharacters: 1_000)
        let plan = manager.plan(history: history, existingSummary: nil, coveredMessageCount: 0, retrievedEvidence: [])
        try expect(plan.coveredMessageCount == 16, "长对话应将早期 16 条消息纳入摘要")
        try expect(plan.recentMessages.count == 8, "长对话应仅保留最近 8 条消息")
        try expect(plan.rollingSummary?.contains("第 0 轮用户问题") == true, "摘要未保留早期会话信息")
        let secondPlan = manager.plan(
            history: history,
            existingSummary: plan.rollingSummary,
            coveredMessageCount: plan.coveredMessageCount,
            retrievedEvidence: []
        )
        try expect(secondPlan.rollingSummary == plan.rollingSummary, "没有新历史时不应重复压缩相同消息")

        let unformatted = "讨论主要集中在以下方面： 一、新人讨论了积分消耗与开发阻塞，需要先降低首次体验成本。二、团队讨论了代码冲突和素材不足，需要拆分模块逐步推进。三、当前仍缺少明确结论，下一步应确认负责人和完成时间。"
        let formatted = ChatResponseFormatter().format(unformatted + unformatted)
        try expect(formatted.contains("\n\n一、") && formatted.contains("\n\n二、"), "长回答没有按编号主题自动分段")
    }

    private static func verifyPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let capture = makeCapture(text: "本地持久化验证", app: "Recall")
        try await store.addCapture(capture)
        let reloaded = try FileMemoryStore(storage: storage)
        let snapshot = await reloaded.snapshot()
        try expect(snapshot.captures.count == 1, "重新加载后记录丢失")
        try expect(snapshot.captures.first?.ocrText == "本地持久化验证", "重新加载后的 OCR 文本不一致")
    }

    private static func verifyCustomModelConfigurationPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let custom = LLMConfiguration(
            provider: .anthropicCompatible,
            baseURLString: "https://example.invalid/custom-anthropic",
            model: "my-custom-model",
            apiKey: "plain-text-test-key"
        )
        try await store.updateLLMConfiguration(custom)
        let reloaded = try FileMemoryStore(storage: storage)
        let restored = await reloaded.snapshot().llmConfiguration
        try expect(restored.provider == .anthropicCompatible, "自定义模型类型没有保存")
        try expect(restored.baseURLString == custom.baseURLString, "自定义 API 地址没有保存")
        try expect(restored.model == custom.model, "自定义模型名称没有保存")
        try expect(restored.apiKey == "plain-text-test-key", "普通文本 API Key 没有保存")
    }

    private static func verifyMiniMaxAuthenticationHeaders() async throws {
        HeaderInspectingURLProtocol.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [HeaderInspectingURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let configuration = LLMConfiguration(
            provider: .anthropicCompatible,
            baseURLString: "https://api.minimaxi.com/anthropic",
            model: "MiniMax-M3"
        )
        let evidence = makeCapture(text: "MiniMax 认证头离线验证", app: "Verifier")
        let response = try await CompatibleLLM(configuration: configuration, apiKey: "test-key", session: session).answer(
            to: LLMRequest(question: "仅回复连接成功", context: [evidence])
        )
        let headers = HeaderInspectingURLProtocol.headers()
        try expect(response.content == "连接成功", "MiniMax 认证头验证未收到模拟响应")
        try expect(headers["X-Api-Key"] == "test-key", "MiniMax 请求缺少 X-Api-Key")
        try expect(headers["Authorization"] == "Bearer test-key", "MiniMax 请求缺少 Bearer 认证回退")
        try expect(headers["anthropic-version"] == "2023-06-01", "MiniMax 请求缺少 Anthropic 版本头")
    }

    private static func verifyLiveAnthropicCompatibility() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["RECALL_LIVE_API_KEY"], !apiKey.isEmpty else {
            throw VerificationError.failed("实时 Anthropic 验证需要 RECALL_LIVE_API_KEY 环境变量。")
        }
        let configuration = LLMConfiguration(
            provider: .anthropicCompatible,
            baseURLString: "https://api.minimaxi.com/anthropic",
            model: "MiniMax-M3.0",
            maxOutputTokens: 96
        )
        let evidence = makeCapture(text: "Recall 的测试记忆只允许回答 LIVE_MODEL_OK。", app: "Verifier")
        let answer = try await CompatibleLLM(configuration: configuration, apiKey: apiKey).answer(
            to: LLMRequest(question: "只回答 LIVE_MODEL_OK", context: [evidence])
        )
        let normalizedAnswer = answer.content.replacingOccurrences(of: " ", with: "")
        try expect(!normalizedAnswer.isEmpty, "实时模型没有返回可解析文本")
        try expect(!normalizedAnswer.contains("记忆证据为空") && !normalizedAnswer.contains("没有可用记忆"), "实时模型忽略了已提供的记忆证据")
        try expect(answer.citedCaptureIDs == [evidence.id], "实时模型回答没有保留本地记忆引用")
    }

    @MainActor
    private static func verifyTodayQuestionUsesTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let capture = makeCapture(text: "上午完成了 Recall 的时间线检索修复。", app: "Xcode")
        try await store.addCapture(capture)
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .localOnly))

        let answer = try await MemoryAssistant(store: store).ask("今天做了什么？")
        try expect(answer.citations == [capture.id], "今天的问题没有引用当天的时间线记录")
        try expect(answer.content.contains("时间线检索修复"), "今天的问题没有返回当天的记录内容")
    }

    private static func verifyLocalAnswer() async throws {
        let capture = makeCapture(text: "会议结论：周五提交设计方案", app: "Notes")
        let answer = try await ExtractiveMemoryResponder().answer(to: LLMRequest(question: "什么时候提交？", context: [capture]))
        try expect(answer.citedCaptureIDs == [capture.id], "本地回答缺少来源引用")
        try expect(answer.content.contains("周五提交设计方案"), "本地回答未包含检索记录")
    }

    private static func makeCapture(text: String, app: String, createdAt: Date = .now) -> CaptureRecord {
        CaptureRecord(
            eventTemplate: .manualMoment,
            createdAt: createdAt,
            sourceAppName: app,
            sourceBundleIdentifier: "com.example.\(app.lowercased())",
            windowTitle: "验证窗口",
            contentHash: UUID().uuidString,
            ocrText: text,
            summary: text,
            tags: []
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationError.failed(message) }
    }
}

private final class HeaderInspectingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let requestLock = NSLock()
    nonisolated(unsafe) private static var capturedHeaders: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestLock.lock()
        Self.capturedHeaders = request.allHTTPHeaderFields ?? [:]
        Self.requestLock.unlock()

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let body = Data("{\"content\":[{\"type\":\"text\",\"text\":\"连接成功\"}]}".utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        requestLock.lock()
        capturedHeaders = [:]
        requestLock.unlock()
    }

    static func headers() -> [String: String] {
        requestLock.lock()
        defer { requestLock.unlock() }
        return capturedHeaders
    }
}

@MainActor
private final class MockCapturer: ScreenCapturing {
    func capture(scope: CaptureScope) async throws -> CapturePayload {
        CapturePayload(
            imageData: scope == .textOnly ? nil : Data("fake-png-binary".utf8),
            sourceAppName: "Mock Editor",
            sourceBundleIdentifier: "com.example.mockeditor",
            windowTitle: scope == .textOnly ? nil : "设计文档"
        )
    }

    func requestScreenRecordingAccess() -> Bool { true }
}

private struct MockRecognizer: TextRecognizing {
    func recognizeText(in imageData: Data) async throws -> String {
        "请联系 alice@example.com，密码: demo-secret"
    }
}

enum VerificationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}
