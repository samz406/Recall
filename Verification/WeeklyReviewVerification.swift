import Foundation
import RecallKit

/// All fixtures are invented. No real screenshots, OCR or personal records.
enum WeeklyReviewVerification {
    static func run() async throws {
        try await verifyEvidenceAndScopes()
        try await verifyTemplatesAndCoverage()
        try verifyCalendarAndSchedules()
        try await verifyPersistenceAndDeletion()
        try await verifyModelBoundary()
    }
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; return c
    }
    private static func date(_ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    private static func note(_ title: String, _ detail: String, _ status: WorkEpisodeStatus, _ day: Int,
                             category: ReviewCategory = .unclassified) throws -> CaptureRecord {
        try ManualMatterNote(title: title, detail: detail, status: status, eventAt: date(day), reviewCategory: category).capture(recordedAt: date(day))
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
    }
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    private static func verifyEvidenceAndScopes() async throws {
        let work = try note("Orion 账单导出", "分页边界修复已通过验证，尚未确认发布。", .completed, 20, category: .work)
        let life = try note("周末植物观察", "和家人记录了院中植物的叶片变化。", .explored, 19, category: .personal)
        let learning = try note("木刻基础练习", "尝试两种握刀方式，留下第一张练习作品。", .explored, 21, category: .learning)
        let other = CaptureRecord(eventTemplate: .manualMoment, createdAt: date(20), windowTitle: "外部评审",
            contentHash: "synthetic-other", ocrText: "[聊天·对方] Orion 评审文档已经全部提交。")
        let unknown = CaptureRecord(eventTemplate: .manualMoment, createdAt: date(20), contentHash: "synthetic-unknown",
            ocrText: "[聊天·角色未知] Orion 生产发布已完成。")
        let article = CaptureRecord(eventTemplate: .webResearchClip, createdAt: date(20), contentHash: "synthetic-article",
            ocrText: "文章观点：今天需要完成所有任务，明天继续优化人生。")
        let personal = CaptureRecord(eventTemplate: .manualMoment, createdAt: date(20), contentHash: "synthetic-life",
            ocrText: "[聊天·自己] 我参加了城市植物观察活动，记录了三种叶片的区别。")
        let state = RecallState(captures: [work, life, learning, other, unknown, article, personal])
        let engine = WeeklyReviewEngine(), period = ReviewPeriod.make(.currentWeek, at: date(21, 20), calendar: calendar)
        let general = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .personal), now: date(21, 20))
        try expect(general.items.count == 4, "个人周回顾应保留工作、学习和生活，不收录对方、未知角色或文章观点")
        try expect(!general.markdown.contains("人生") && !general.markdown.contains("生产发布已完成"), "周回顾不能借用文章观点或未知角色完成信息")
        let workReport = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .work), now: date(21, 20))
        try expect(workReport.items.count == 1 && !workReport.markdown.contains("叶片") && !workReport.markdown.contains("木刻"), "工作周报应隔离生活和学习内容")
        let allIDs = Set(engine.topics(in: state).map(\.id))
        let selected = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .project), scope: ReviewScope(topicIDs: allIDs), now: date(21, 20))
        try expect(selected.items.count == 1, "即使全选，明确标为生活/学习的主题也不得进入工作对外版本")
        let study = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .learning), now: date(21, 20))
        try expect(study.items.count == 1 && study.items[0].section == .notes && !study.markdown.contains("掌握"), "学习记录不得自动升级成已经掌握")
        do {
            _ = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .personal), scope: ReviewScope(useSelectedTopics: true), now: date(21, 20))
            throw Failure(message: "手动全不选时不能回退为全选")
        } catch let error as WeeklyReviewError { try expect(error == .noEvidence, "无选择的范围应明确无数据") }
    }

    private static func verifyTemplatesAndCoverage() async throws {
        let before = try note("Lumen 发票下载", "仍然受阻，缺少测试数据。", .blocked, 15, category: .work)
        let early = try note("Lumen 发票下载", "测试数据已补齐，开始复核导出内容。", .progressed, 19, category: .work)
        let outcome = try note("Lumen 发票下载", "发票下载已通过空数据和分页回归测试。", .completed, 20, category: .work)
        let follow = try note("Lumen 发票下载", "我明天会提交发票下载的发布申请。", .pending, 21, category: .work)
        let state = RecallState(captures: [before, early, outcome, follow])
        var template = ReviewTemplate(kind: .work, id: "custom-format")
        template.name = "团队周报"; template.sections = [.plans, .open, .progress, .notes]
        template.headings[ReviewSection.progress.rawValue] = "本周交付"; template.length = .detailed
        let period = ReviewPeriod.make(.currentWeek, at: date(21, 20), calendar: calendar)
        let report = try await WeeklyReviewEngine().generate(in: state, period: period, template: template, now: date(21, 20))
        try expect(report.items.count == 1 && report.items[0].excerpts.count == 2, "同一主题整周变化应合并，不能只取最后一句")
        try expect(report.items[0].previous?.text == before.manualMatter?.detail, "必须有范围之前的真实对照记录")
        try expect(report.markdown.contains("本周交付") && report.markdown.contains("空数据和分页回归"), "模板改变表达与顺序，不得漏掉已验证结果")
        try expect(!report.markdown.contains("## 待解决") && !report.markdown.contains("## 补充记录"), "没有内容的栏目必须隐藏")
        try expect(report.items[0].section == .progress && report.items[0].nextAction == follow.manualMatter?.detail
            && report.items[0].nextActionSourceIDs == [follow.id], "后来的待办不能覆盖整周成果，且后续安排要独立关联来源")
        try expect(!report.items[0].id.contains("发票") && !report.items[0].id.contains("Lumen"), "范围和分类标识不能保留可识别的原始主题文字")
        try expect(report.sourceIDs == Set([before.id, early.id, outcome.id, follow.id]), "回顾每项应关联到整周及对照的原始依据")
        var changedTemplate = template; changedTemplate.name = "另一个名字"
        try expect(report.template.name == "团队周报", "模板更改不能静默改写历史快照")
        let old = CaptureRecord(eventTemplate: .manualMoment, createdAt: date(15), windowTitle: "Orion 明细导出",
            contentHash: "synthetic-repeat-a", ocrText: "[聊天·自己] Orion 明细导出已验证通过。")
        var repeatShot = old; repeatShot.id = UUID(); repeatShot.createdAt = date(20); repeatShot.contentHash = "synthetic-repeat-b"
        let repeated = RecallState(captures: [old, repeatShot])
        do {
            _ = try await WeeklyReviewEngine().generate(in: repeated, period: period, template: ReviewTemplate(kind: .personal), now: date(21, 20))
            throw Failure(message: "重新浏览旧结果不能制造本周成果")
        } catch let error as WeeklyReviewError { try expect(error == .noEvidence, "重复截图应只合并来源") }
        let submittedTemplate = template
        let cancelled = Task {
            try Task.checkCancellation()
            return try await WeeklyReviewEngine().generate(in: state, period: period, template: submittedTemplate, now: date(21, 20))
        }
        cancelled.cancel()
        do { _ = try await cancelled.value } catch is CancellationError { }
    }

    private static func verifyCalendarAndSchedules() throws {
        let now = date(21, 20)
        let complete = ReviewPeriod.make(.previousWeek, at: now, calendar: calendar)
        try expect(complete.start == date(12, 0) && complete.end == date(19, 0), "完整自然周应以本地周一零点分界")
        try expect(!complete.contains(date(19, 0)) && complete.contains(date(18, 23)), "相邻周边界不能重复归属")
        let monthEnd = calendar.date(byAdding: .day, value: 31, to: date(1, 0))!
        let overLimit = calendar.date(byAdding: .day, value: 32, to: date(1, 0))!
        try expect(ReviewPeriod(start: date(1, 0), end: monthEnd, timeZoneIdentifier: "Asia/Shanghai").isValid
            && !ReviewPeriod(start: date(1, 0), end: overLimit, timeZoneIdentifier: "Asia/Shanghai").isValid,
            "自选范围必须按本地自然日校验 31 天，不能放行 32 天")
        let recent = ReviewPeriod.make(.recentSeven, at: now, calendar: calendar)
        try expect(recent.start == date(15, 0) && recent.end == now, "最近七天应包含今天和前六个本地自然日")
        var plan = ReviewSchedule(template: ReviewTemplate(kind: .work))
        plan.weekday = 6; plan.hour = 18; plan.timeZoneIdentifier = "Asia/Shanghai"
        plan.nextRunAt = plan.nextTrigger(after: date(15))
        try expect(plan.nextRunAt == date(16, 18), "生成时刻必须使用计划时区和指定星期")
        try expect(!plan.isDue(at: date(16, 17)) && plan.isDue(at: now), "启动后能识别错过的计划")
        try expect(plan.effectiveTrigger(at: date(30, 19)) == date(30, 18), "多周离线只补最近一次，不使用启动时间伪装完整周")
        plan.failureCount = 1; plan.retryAfter = now.addingTimeInterval(300)
        try expect(!plan.isDue(at: now) && plan.effectiveTrigger(at: date(30, 19)) == date(16, 18), "重试必须保持原计划的范围，并遵守退避时间")
        plan.isEnabled = false
        try expect(!plan.isDue(at: date(30, 19)), "关闭计划必须停止补跑")
        var dst = ReviewSchedule(template: ReviewTemplate(kind: .personal))
        dst.timeZoneIdentifier = "America/Los_Angeles"; dst.weekday = 1; dst.hour = 1; dst.minute = 30
        let autumn = dst.calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0))!
        let first = dst.nextTrigger(after: autumn)!
        try expect(dst.nextTrigger(after: first)!.timeIntervalSince(first) > 6 * 86_400, "夏令时重复时刻不能在同一周执行两次")
    }

    private static func verifyPersistenceAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Recall-Weekly-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root), store = try FileMemoryStore(storage: storage)
        let note = ManualMatterNote(title: "Nacre 清单整理", detail: "清单已归档，保留三条修改理由。", status: .completed, eventAt: date(20), reviewCategory: .work)
        _ = try await store.addManualMatter(note, now: date(20))
        let state = await store.snapshot(), period = ReviewPeriod.make(.currentWeek, at: date(21, 20), calendar: calendar)
        let report = try await WeeklyReviewEngine().generate(in: state, period: period, template: ReviewTemplate(kind: .work), now: date(21, 20))
        _ = try await store.commitWeeklyReport(report)
        try await store.editWeeklyReport(id: report.id, markdown: "# 人工调整\n清单整理已完成。")
        let reread = try FileMemoryStore(storage: storage)
        let reloaded = await reread.snapshot()
        try expect(reloaded.weeklyReports.first?.editedMarkdown?.contains("人工调整") == true, "回顾快照和编辑内容必须持久保存")
        let captureID = state.captures[0].id
        let deletion = try await store.moveCapturesToRecentlyDeleted(ids: [captureID], reason: .sensitive, suppressSimilar: false, now: date(21))!
        let deleted = await store.snapshot()
        try expect(deleted.weeklyReports.first?.isReadable == false && deleted.weeklyReports.first?.items.isEmpty == true
            && deleted.weeklyReports.first?.editedMarkdown == nil, "删除来源必须清除生成正文及用户编辑，不能只隐藏")
        _ = try await store.restoreRecentlyDeleted(id: deletion.id, now: date(22))
        let restored = await store.snapshot()
        try expect(restored.weeklyReports.first?.editedMarkdown?.contains("人工调整") == true, "与来源同一事务恢复的回顾应保留人工编辑")
        let reportDeletion = try await store.deleteWeeklyReport(id: report.id, now: date(22))!
        _ = try await store.deleteCapture(id: captureID)
        _ = try await store.restoreRecentlyDeleted(id: reportDeletion.id, now: date(23))
        let scrubbed = await store.snapshot()
        try expect(scrubbed.weeklyReports.first?.isReadable == false && scrubbed.weeklyReports.first?.editedMarkdown == nil,
            "回顾单独在回收站期间删除来源，不能通过恢复回顾找回已删除的内容")

        _ = try await store.addManualMatter(note, now: date(21))
        let again = await store.snapshot()
        let fresh = try await WeeklyReviewEngine().generate(in: again, period: period, template: ReviewTemplate(kind: .work), now: date(21, 20))
        _ = try await store.commitWeeklyReport(fresh)
        try await store.saveMatterCorrection(MatterCorrection(evidenceIDs: [again.captures[0].id], kind: .inaccurate))
        let corrected = await store.snapshot()
        try expect(corrected.weeklyReports.first(where: { $0.id == fresh.id })?.isReadable == false, "更正来源必须使旧周回顾失效")
        do { _ = try await store.commitWeeklyReport(fresh); throw Failure(message: "不得写入更正前仍在生成的回顾") }
        catch let error as WeeklyReviewError { try expect(error == .changedSources, "并发写入要检查来源版本") }

        var template = ReviewTemplate(kind: .work, id: "synthetic-format"); template.name = "合成团队周报"
        try await store.saveReviewTemplate(template)
        var plan = ReviewSchedule(template: template); plan.timeZoneIdentifier = "Asia/Shanghai"
        try await store.saveReviewSchedule(plan, now: date(21))
        plan = await store.snapshot().reviewSchedules[0]
        try expect(plan.nextRunAt != nil && !plan.isDue(at: date(21)), "新计划只从未来执行，不自动追溯生成")
        let previousNext = plan.nextRunAt!
        try await store.deferReviewSchedule(plan, noEvidence: false, now: previousNext)
        let retry = await store.snapshot().reviewSchedules[0]
        try expect(retry.failureCount == 1 && retry.retryAfter! > previousNext, "失败应持久化退避并支持重启后重试")
        try await store.deferReviewSchedule(retry, noEvidence: true, now: previousNext.addingTimeInterval(300))
        let settled = await store.snapshot().reviewSchedules[0]
        try expect(settled.nextRunAt! > previousNext && settled.failureCount == 0, "没有记录的周期应安静结束，不能反复生成空报告")
        _ = try await store.addManualMatter(ManualMatterNote(title: "合成交付计划", detail: "交付清单已核对。", status: .completed,
            eventAt: date(20), reviewCategory: .work), now: date(21))
        var testPlan = ReviewSchedule(template: template)
        testPlan.weekday = 4; testPlan.hour = 20; testPlan.timeZoneIdentifier = "Asia/Shanghai"
        try await store.saveReviewSchedule(testPlan, now: date(21))
        testPlan = await store.snapshot().reviewSchedules.first { $0.id == testPlan.id }!
        let active = await store.snapshot()
        var scheduledReport = try await WeeklyReviewEngine().generate(in: active, period: period, template: template, now: date(21, 20))
        scheduledReport.refinementPending = true
        scheduledReport.scheduledFor = testPlan.nextRunAt
        let saved = try await store.commitWeeklyReport(scheduledReport, schedule: testPlan, categories: active.reviewCategories, now: date(21, 20))
        let waiting = await store.snapshot().reviewSchedules.first { $0.id == testPlan.id }!
        try expect(waiting.lastReportID == saved.id && waiting.failureCount == 1, "模型失败应保留同一份可读的本地版本并安排重试")
        var refined = scheduledReport; refined.refinementPending = false; refined.modelAssisted = true
        _ = try await store.commitWeeklyReport(refined, replacing: saved.id, schedule: waiting, now: waiting.retryAfter!)
        let successful = await store.snapshot()
        try expect(successful.weeklyReports.filter { $0.id == saved.id }.count == 1, "重试成功不能重复新增同一期报告")
        do {
            _ = try await store.commitWeeklyReport(refined, replacing: saved.id, schedule: waiting)
            throw Failure(message: "完成后不能用旧计划状态重复提交和通知")
        } catch let error as WeeklyReviewError { try expect(error == .changedSources, "计划状态应提供幂等提交保护") }
        var againPlan = ReviewSchedule(template: template)
        againPlan.weekday = 4; againPlan.hour = 20; againPlan.timeZoneIdentifier = "Asia/Shanghai"
        try await store.saveReviewSchedule(againPlan, now: date(21))
        againPlan = await store.snapshot().reviewSchedules.first { $0.id == againPlan.id }!
        var pendingCopy = scheduledReport; pendingCopy.id = UUID()
        let pendingSaved = try await store.commitWeeklyReport(pendingCopy, schedule: againPlan, now: date(21, 20))
        _ = try await store.deleteWeeklyReport(id: pendingSaved.id, now: date(21, 21))
        let stopped = await store.snapshot().reviewSchedules.first { $0.id == againPlan.id }!
        try expect(stopped.lastReportID == nil && stopped.retryAfter == nil && stopped.nextRunAt! > date(21, 21),
            "删除待重试报告后不能自动将它重新生成")
        try await store.clearAllMemoryData()
        let cleared = await store.snapshot()
        try expect(cleared.weeklyReports.isEmpty && cleared.reviewCategories.isEmpty && !cleared.reviewSchedules.isEmpty,
            "清空记忆必须清除周回顾与分类，保留明确设置的计划")
        let legacy = try JSONDecoder().decode(RecallState.self, from: Data("{}".utf8))
        try expect(legacy.weeklyReports.isEmpty && legacy.reviewSchedules.isEmpty && legacy.reviewTemplates.isEmpty, "旧状态迁移不得自动打开周回顾计划")
    }

    private static func verifyModelBoundary() async throws {
        let source = try note("Orion 联系测试", "完成联络表核对；测试地址 fake.person@example.test。", .completed, 20, category: .work)
        let privateNote = try note("合成私人记录", "PRIVATE-SYNTHETIC-MARKER 只属于生活。", .explored, 20, category: .personal)
        var state = RecallState(captures: [source, privateNote])
        let period = ReviewPeriod.make(.currentWeek, at: date(21, 20), calendar: calendar)
        let responder = WeeklyProbe(mode: .valid)
        _ = try await WeeklyReviewEngine().generate(in: state, period: period, template: ReviewTemplate(kind: .work), responder: responder, now: date(21, 20))
        let noCloudCount = await responder.requestCount()
        try expect(noCloudCount == 0, "全局云端关闭时不能因传入 responder 而外发")
        state.privacy.cloudUseEnabled = true
        let report = try await WeeklyReviewEngine().generate(in: state, period: period, template: ReviewTemplate(kind: .work), responder: responder, now: date(21, 20))
        let request = await responder.lastRequest()!
        let sent = request.question + request.context.map(\.ocrText).joined()
        try expect(!sent.contains("fake.person@example.test") && !sent.contains("PRIVATE-SYNTHETIC-MARKER")
            && request.context.allSatisfy { $0.imageRelativePath == nil && $0.manualMatter == nil && $0.windowTitle == nil },
            "模型只能看到所选工作事实的最小化脱敏副本")
        try expect(report.modelAssisted && !report.refinementPending && report.items.count == 1, "有效模型选择不能丢失本地事实")
        let malicious = WeeklyProbe(mode: .invented)
        let rejected = try await WeeklyReviewEngine().generate(in: state, period: period, template: ReviewTemplate(kind: .work), responder: malicious, now: date(21, 20))
        try expect(rejected.refinementPending && !rejected.modelAssisted && !rejected.markdown.contains("虚构成果"), "虚构来源与自由文本必须退回可用的本地整理")
        let failing = WeeklyProbe(mode: .failure)
        let fallback = try await WeeklyReviewEngine().generate(in: state, period: period, template: ReviewTemplate(kind: .work), responder: failing, now: date(21, 20))
        try expect(fallback.refinementPending && fallback.items.count == 1, "模型错误不应丢失事实或阻塞阅读")
    }
}

private actor WeeklyProbe: LLMResponding {
    enum Mode { case valid, invented, failure }
    let mode: Mode
    var requests: [LLMRequest] = []
    init(mode: Mode) { self.mode = mode }
    func requestCount() -> Int { requests.count }
    func lastRequest() -> LLMRequest? { requests.last }
    func answer(to request: LLMRequest) async throws -> LLMAnswer {
        requests.append(request)
        switch mode {
        case .valid: return LLMAnswer(content: #"{"selections":[]}"#, citedCaptureIDs: [])
        case .invented: return LLMAnswer(content: #"{"selections":[{"topicID":"虚构成果","excerptIDs":["00000000-0000-0000-0000-000000000001"]}]}"#, citedCaptureIDs: [])
        case .failure: throw URLError(.notConnectedToInternet)
        }
    }
}
