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
        try await verifyMultiTopicAndLifeDeduplication()
        try await verifyImportantEvidence()
        try await verifyCompositionQuality()
        try await verifyIndependentRefinement()
        try await verifyProviderProtocol()
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
        try expect(general.items.first(where: { $0.sourceIDs.contains(personal.id) })?.excerpts.first?.eventTimeKnown == false
            && general.items.first(where: { $0.sourceIDs.contains(work.id) })?.excerpts.first?.eventTimeKnown == true,
            "截图采集时间和用户明确提供的发生时间必须区分，不能把采集时间默认为真实发生时间")
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
        try expect(!plan.isDue(at: now) && plan.effectiveTrigger(at: date(30, 19)) == date(30, 18), "退避保留，但旧失败不能阻塞新一期计划")
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
        testPlan.weekday = 4; testPlan.hour = 20; testPlan.timeZoneIdentifier = "Asia/Shanghai"; testPlan.useModel = true
        try await store.saveReviewSchedule(testPlan, now: date(21))
        testPlan = await store.snapshot().reviewSchedules.first { $0.id == testPlan.id }!
        let active = await store.snapshot()
        var scheduledReport = try await WeeklyReviewEngine().generate(in: active, period: period, template: template, now: date(21, 20))
        scheduledReport.refinementPending = true
        scheduledReport.scheduledFor = testPlan.nextRunAt
        let saved = try await store.commitWeeklyReport(scheduledReport, schedule: testPlan, categories: active.reviewCategories, now: date(21, 20))
        let waiting = await store.snapshot().reviewSchedules.first { $0.id == testPlan.id }!
        try expect(waiting.lastReportID == saved.id && waiting.failureCount == 0 && waiting.nextRunAt! > date(21, 20)
            && saved.refinementAttempts == 1, "模型失败应保存本地报告、独立安排重试，同时推进下一期")
        var refined = saved; refined.refinementPending = false; refined.modelAssisted = true
        _ = try await store.commitWeeklyRefinement(refined, expected: saved, schedule: waiting, now: saved.refinementRetryAfter!)
        let successful = await store.snapshot()
        try expect(successful.weeklyReports.filter { $0.id == saved.id }.count == 1, "重试成功不能重复新增同一期报告")
        do {
            _ = try await store.commitWeeklyRefinement(refined, expected: saved, schedule: waiting, now: saved.refinementRetryAfter!)
            throw Failure(message: "完成后不能用旧报告状态重复提交和通知")
        } catch let error as WeeklyReviewError { try expect(error == .changedSources, "报告快照应提供幂等提交保护") }
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
    enum Mode { case valid, invented, failure, inventedNumber, stateDrift, missingOutcome, supportedDate }
    let mode: Mode
    var requests: [LLMRequest] = []
    init(mode: Mode) { self.mode = mode }
    func requestCount() -> Int { requests.count }
    func lastRequest() -> LLMRequest? { requests.last }
    func allRequests() -> [LLMRequest] { requests }
    func answer(to request: LLMRequest) async throws -> LLMAnswer {
        requests.append(request)
        if mode == .failure { throw URLError(.notConnectedToInternet) }
        let topics = try request.context.map { try JSONSerialization.jsonObject(with: Data($0.ocrText.utf8)) as! [String: Any] }
        let content: [String: Any]
        if request.purpose == .weeklyAudit {
            content = ["checks": topics.map { topic in
                ["topicID": topic["topicID"]!, "supported": mode != .stateDrift,
                 "correctAttribution": true, "preservesState": mode != .stateDrift, "coversKeyFacts": true] as [String: Any]
            }]
        } else {
            content = ["items": topics.map { topic -> [String: Any] in
                let facts = topic["facts"] as! [[String: Any]]
                var ids = topic["requiredEvidenceIDs"] as! [String]
                var summary = facts.map { $0["text"] as! String }.joined(separator: " ")
                if (topic["title"] as? String) == "Orion 联系测试" { summary = "联络表已完成核对，测试地址保留在来源记录中。" }
                if mode == .supportedDate { summary = "10月20日完成了联络表核对，测试地址保留在来源记录中。" }
                if mode == .inventedNumber { summary = "联络表已完成核对，带来了 99999 元收益。" }
                if mode == .stateDrift { summary = "联络表已完成上线，全部相关问题均已解决。" }
                if mode == .missingOutcome { ids = Array(ids.prefix(1)) }
                return ["topicID": mode == .invented ? "虚构成果" : topic["topicID"]!,
                        "title": topic["title"]!, "summary": summary, "evidenceIDs": ids]
            }]
        }
        return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: content), as: UTF8.self), citedCaptureIDs: [])
    }
}

private extension WeeklyReviewVerification {
    static func verifyMultiTopicAndLifeDeduplication() async throws {
        let shot = CaptureRecord(eventTemplate: .manualMoment, createdAt: date(20), windowTitle: "Orion 账单导出",
            contentHash: "synthetic-multi-topic", ocrText: """
            [聊天·自己] Orion 账单导出已定位分页偏移。
            [聊天·自己] Orion 账单导出已验证通过。
            [聊天·自己] Nova 图像压缩仍然失败。
            [聊天·对方] Vega 文件上传已完成。
            """)
        let engine = WeeklyReviewEngine(), period = ReviewPeriod.make(.currentWeek, at: date(21, 20), calendar: calendar)
        let report = try await engine.generate(in: RecallState(captures: [shot]), period: period,
            template: ReviewTemplate(kind: .personal), now: date(21, 20))
        try expect(report.items.count == 2 && report.items.flatMap(\.excerpts).count == 3,
            "一张记录中的两个事项及同一事项的两次变化都必须保留，对方成果不能混入")
        try expect(Set(report.items.flatMap(\.excerpts).map(\.id)).count == 3 && report.sourceIDs == [shot.id],
            "事项事件 ID 必须独立，来源仍指向同一张可删除记录")
        let again = try await engine.generate(in: RecallState(captures: [shot]), period: period,
            template: ReviewTemplate(kind: .personal), now: date(21, 20))
        try expect(Set(again.items.flatMap(\.excerpts).map(\.id)) == Set(report.items.flatMap(\.excerpts).map(\.id)),
            "重复重建不得生成不稳定的事件 ID")
        var earlierShot = shot; earlierShot.createdAt = date(15)
        var repeatShot = shot; repeatShot.id = UUID()
        let repeatedTopics = engine.topics(in: RecallState(captures: [repeatShot, earlierShot]))
        try expect(repeatedTopics.flatMap(\.events).count == 3 && repeatedTopics.flatMap(\.events).allSatisfy { $0.date == date(15) },
            "多事项截图重拍不能让早期中间状态再次出现并制造本周进展")
        let old = CaptureRecord(eventTemplate: .manualMoment, createdAt: date(15), contentHash: "synthetic-old-learning",
            ocrText: "[聊天·自己] 我学习了木刻基础技法，尝试了两种握刀方式。\n[聊天·自己] 我参加了城市植物观察活动，记录了三种叶片。")
        var repeated = old; repeated.id = UUID(); repeated.createdAt = date(20)
        let correctedState = RecallState(captures: [old, repeated], matterCorrections: [MatterCorrection(evidenceIDs: [repeated.id], kind: .eventDate, eventAt: date(20))])
        try expect(engine.topics(in: correctedState).allSatisfy { $0.events.count == 2 },
            "用户明确更正的另一次发生时间必须保留，不能被截图去重覆盖")
        for records in [[repeated, old], [old, repeated]] {
            let topics = engine.topics(in: RecallState(captures: records))
            try expect(topics.count == 2 && topics.allSatisfy { $0.latest.date == date(15) && Set($0.evidenceIDs) == [old.id, repeated.id] },
                "生活和学习重复截图必须保留首次日期与全部来源，不受加载顺序影响")
            do {
                _ = try await engine.generate(in: RecallState(captures: records), period: period,
                    template: ReviewTemplate(kind: .personal), now: date(21, 20))
                throw Failure(message: "旧生活/学习内容不能因为重拍进入本周")
            } catch let error as WeeklyReviewError { try expect(error == .noEvidence, "旧内容应不进入当前范围") }
        }
    }

    static func verifyImportantEvidence() async throws {
        let complete = try note("Orion 分页验收", "Orion 分页验收已通过回归，验证了空数据场景。", .completed, 19)
        let update = try note("Orion 分页验收", "Orion 分页验收补充了两个边界样例。", .progressed, 20)
        let latest = try note("Orion 分页验收", "Orion 分页验收仍然受阻，生产样例尚未补齐。", .blocked, 21)
        let state = RecallState(captures: [latest, update, complete])
        let period = ReviewPeriod.make(.currentWeek, at: date(21, 20), calendar: calendar)
        let report = try await WeeklyReviewEngine().generate(in: state, period: period, template: ReviewTemplate(kind: .personal), now: date(21, 20))
        var item = report.items[0]
        item.featuredIDs = [update.id] // A ranking must not evict either the outcome or latest blocker.
        let brief = item.featured(for: .brief)
        try expect(Set(brief.map(\.id)) == [complete.id, latest.id], "简洁版也必须同时保留早期成果和最新阻碍")
        let probe = WeeklyProbe(mode: .missingOutcome)
        var cloud = state; cloud.privacy.cloudUseEnabled = true
        let rejected = try await WeeklyReviewEngine().generate(in: cloud, period: period, template: ReviewTemplate(kind: .personal), responder: probe, now: date(21, 20))
        try expect(rejected.refinementPending && rejected.items[0].narrative == nil,
            "模型漏掉重要完成结果时必须拒绝，而不是让后面的状态覆盖整周")
        var other = item; other.id = "aaaa"; other.section = .notes; other.excerpts = [item.excerpts[1]]
        var ranked = report; ranked.items = [other, item]
        try expect(ranked.overview.hasPrefix(latest.manualMatter!.detail), "概览按实际重要性，而非主题 ID 顺序")
    }

    static func verifyCompositionQuality() async throws {
        let source = try note("Orion 联系测试", "完成联络表核对；测试地址 fake.person@example.test。", .completed, 20, category: .work)
        var state = RecallState(captures: [source]); state.privacy.cloudUseEnabled = true
        let engine = WeeklyReviewEngine(), period = ReviewPeriod.make(.currentWeek, at: date(21, 20), calendar: calendar)
        for mode in [WeeklyProbe.Mode.inventedNumber, .stateDrift] {
            let report = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .work), responder: WeeklyProbe(mode: mode), now: date(21, 20))
            try expect(report.refinementPending && report.items[0].narrative == nil
                && !report.markdown.contains("99999") && !report.markdown.contains("全部相关问题均已解决"),
                "新数字/收益和虚构上线结论必须被本地校验或独立核对拒绝")
        }
        let dated = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .work), responder: WeeklyProbe(mode: .supportedDate), now: date(21, 20))
        try expect(dated.modelAssisted && !dated.refinementPending, "来源明确的发生日期可以进入正文，不能误报为新数字")
        for kind in ReviewTemplateKind.allCases {
            var template = ReviewTemplate(kind: kind); template.length = .brief
            let probe = WeeklyProbe(mode: .valid)
            let scope = ReviewScope(topicIDs: Set(engine.topics(in: state).map(\.id)))
            let report = try await engine.generate(in: state, period: period, template: template, scope: scope, responder: probe, now: date(21, 20))
            try expect(report.items[0].narrative?.summary == "联络表已完成核对，测试地址保留在来源记录中。"
                && !report.markdown.contains("fake.person@example.test") && report.sourceIDs == [source.id],
                "四种模板必须展示整理后的正文，仍保留原始来源，不再把原句拼贴当成成文")
            let requests = await probe.allRequests()
            try expect(requests.count == 2 && requests[0].purpose == .weeklyComposition && requests[1].purpose == .weeklyAudit,
                "成文与事实核对必须是两个独立协议")
            try expect(requests[0].question.contains("正文不超过 260 字")
                && requests[0].question.contains(template.tone == .formal ? "语言克制、正式" : "语言自然、直接"),
                "模板篇幅和语气必须真正进入成文约束")
        }
        let report = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .work), now: date(21, 20))
        let legacyData = try JSONEncoder().encode(report)
        var object = try JSONSerialization.jsonObject(with: legacyData) as! [String: Any]
        object.removeValue(forKey: "refinementAttempts"); object.removeValue(forKey: "refinementRetryAfter"); object.removeValue(forKey: "refinementDeadline")
        let legacy = try JSONDecoder().decode(WeeklyReport.self, from: JSONSerialization.data(withJSONObject: object))
        try expect(legacy.items[0].narrative == nil && legacy.items[0].excerpts.count == 1, "新增正文与重试字段兼容旧报告")
    }

    static func verifyIndependentRefinement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Recall-Weekly-Retry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileMemoryStore(storage: RecallStorage(rootURL: root))
        _ = try await store.addManualMatter(ManualMatterNote(title: "Orion 联系测试", detail: "联络表核对已完成，测试结果已保留。", status: .completed,
            eventAt: date(20), reviewCategory: .work), now: date(20))
        var privacy = await store.snapshot().privacy; privacy.cloudUseEnabled = true; try await store.updatePrivacy(privacy)
        var plan = ReviewSchedule(template: ReviewTemplate(kind: .work)); plan.useModel = true
        plan.timeZoneIdentifier = "Asia/Shanghai"; plan.weekday = 4; plan.hour = 20
        try await store.saveReviewSchedule(plan, now: date(21))
        plan = await store.snapshot().reviewSchedules[0]
        var report = try await WeeklyReviewEngine().generate(in: await store.snapshot(), period: plan.period(at: date(21, 20)),
            template: plan.template, responder: WeeklyProbe(mode: .failure), now: date(21, 20))
        report.scheduledFor = date(21, 20)
        report = try await store.commitWeeklyReport(report, schedule: plan, now: date(21, 20))
        var snapshot = await store.snapshot(); plan = snapshot.reviewSchedules[0]
        try expect(plan.nextRunAt == date(28, 20), "模型失败必须立即推进下周生成时间")
        let retryTime = report.refinementRetryAfter!
        if case .refine(let selected, _) = WeeklyReviewWork.next(in: snapshot, at: retryTime, modelAvailable: true) {
            try expect(selected.id == report.id, "重试必须指向原报告")
        } else { throw Failure(message: "可用模型应在退避后重试原报告") }
        try expect(WeeklyReviewWork.next(in: snapshot, at: retryTime, modelAvailable: false) == nil, "没有模型连接时不反复尝试外发")
        snapshot.privacy.cloudUseEnabled = false
        if case .generate(_, let trigger) = WeeklyReviewWork.next(in: snapshot, at: date(28, 21), modelAvailable: false) {
            try expect(trigger == date(28, 20), "云端关闭也必须继续下一周本地报告")
        } else { throw Failure(message: "上一期失败不能阻塞下一期") }
        for _ in 0..<2 {
            let time = report.refinementRetryAfter!
            try await store.deferWeeklyRefinement(report, schedule: plan, now: time)
            report = await store.snapshot().weeklyReports.first { $0.id == report.id }!
        }
        try expect(report.refinementAttempts == 3 && !report.canRefine(at: date(21, 23)), "最多三次尝试，不能无限重试")
        var expired = report; expired.refinementAttempts = 1
        try expect(!expired.canRefine(at: date(23)), "超过一天的旧报告不应自动整理")
        try await store.editWeeklyReport(id: report.id, markdown: "# 用户修改\n保留手动整理的内容。")
        do {
            _ = try await store.commitWeeklyRefinement(report, expected: expired, schedule: plan, now: retryTime)
            throw Failure(message: "过期响应不能覆盖用户编辑")
        } catch let error as WeeklyReviewError { try expect(error == .changedSources, "并发编辑应拒绝写入") }
        var midnight = plan; midnight.weekday = 2; midnight.hour = 0
        try expect(midnight.period(at: date(19, 0)).start == date(12, 0)
            && midnight.period(at: date(19, 0)).end == date(19, 0), "周一零点应回顾刚结束的一周，不反复生成空范围")
    }

    static func verifyProviderProtocol() async throws {
        let source = try note("Orion 联系测试", "联络表核对已完成，测试结果已保留。", .completed, 20, category: .work)
        var state = RecallState(captures: [source]); state.privacy.cloudUseEnabled = true
        let period = ReviewPeriod.make(.currentWeek, at: date(21, 20), calendar: calendar)
        for provider in [LLMProviderKind.openAICompatible, .anthropicCompatible] {
            WeeklyReviewURLProtocol.reset()
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WeeklyReviewURLProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let responder = CompatibleLLM(configuration: LLMConfiguration(provider: provider, baseURLString: "https://example.invalid/v1", model: "synthetic-model"),
                apiKey: "synthetic-placeholder", session: session)
            let report = try await WeeklyReviewEngine().generate(in: state, period: period, template: ReviewTemplate(kind: .work), responder: responder, now: date(21, 20))
            try expect(report.modelAssisted && !report.refinementPending && report.items[0].narrative != nil,
                "两种真实客户端请求都应经过 JSON 成文与核对并可保存正文")
            let bodies = try WeeklyReviewURLProtocol.bodies().map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
            try expect(bodies.count == 2 && bodies[0]["max_tokens"] as? Int == 4_000 && bodies[1]["max_tokens"] as? Int == 2_000,
                "周回顾不能沿用聊天默认 1000 token 截断多项正文")
            for body in bodies {
                let messages = body["messages"] as! [[String: Any]]
                let system = (body["system"] as? String) ?? (messages.first?["content"] as? String) ?? ""
                try expect(system.contains("只输出任务指定结构的 JSON") && !system.contains("每个事实性结论后以 [数字]")
                    && !system.contains("回答超过 180 个字"), "任务协议不能混入聊天段落与引用要求")
            }
        }
    }
}

/// Intercepts both HTTP providers without a network connection, exercising their actual
/// JSON serialization, system/user roles, token budgets and response parsers.
private final class WeeklyReviewURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [Data] = []
    static func reset() { lock.lock(); defer { lock.unlock() }; captured = [] }
    static func bodies() -> [Data] { lock.lock(); defer { lock.unlock() }; return captured }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                }
            }
            Self.lock.lock(); Self.captured.append(data); Self.lock.unlock()
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let system = (body["system"] as? String) ?? (messages.first?["content"] as? String) ?? ""
            let topics = try system.components(separatedBy: "\n").filter { $0.hasPrefix("{") }.map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
            let result: [String: Any]
            if system.contains("逐项核验") {
                result = ["checks": topics.map { ["topicID": $0["topicID"]!, "supported": true, "correctAttribution": true, "preservesState": true, "coversKeyFacts": true] }]
            } else {
                result = ["items": topics.map { ["topicID": $0["topicID"]!, "title": "联络表完成核对", "summary": "联络表已完成核对，测试结果保留在原始记录中。", "evidenceIDs": $0["requiredEvidenceIDs"]!] }]
            }
            let text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
            let response: [String: Any] = body["system"] == nil
                ? ["choices": [["message": ["role": "assistant", "content": text]]]]
                : ["content": [["type": "text", "text": text]]]
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: response))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}
