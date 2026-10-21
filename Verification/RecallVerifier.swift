import CoreGraphics
import Foundation
import RecallKit

@main
struct RecallVerifier {
    static func main() async {
        do {
            try await MemoryKnowledgeVerification.run()
            try await WeeklyReviewVerification.run()
            try verifyMatterFilesAndReview()
            try verifyMatterEvidenceQuality()
            try verifyMatterProgressQualityAndFreshness()
            try verifyExperienceAndQuestionSelection()
            try await verifyMatterCorrectionPersistence()
            try await verifyManualMatterLifecycle()
            try verifyDefaultEventTemplates()
            try await verifyEventRuleMigration()
            try verifyPrivacy()
            try verifyLocalSummaryNoiseFiltering()
            try verifyCapturePresentation()
            try verifyConversationRoleRecognition()
            try verifyConversationRegionRecognition()
            try ConversationLayoutVerification.runGeometry()
            try ConversationLayoutVerification.runEvidence()
            try await ConversationLayoutVerification.runVision()
            try await ConversationLayoutVerification.runChannel()
            try verifySearch()
            try verifyChineseNaturalLanguageSearch()
            try verifyNaturalLanguageTimeRanges()
            try verifyTimelineDayGrouping()
            try verifyTimelineDayFiltering()
            try verifyReminders()
            try verifyReminderPrecision()
            try verifyReminderTimeAndRecurrence()
            try verifyReminderOccurrenceLifecycle()
            try verifyReminderContextAndOwnership()
            try verifyReminderLearning()
            try await verifyReminderSchedulePersistence()
            try await verifyReminderDeletionAndCheckpoint()
            try await verifyDailySummaryGeneration()
            try await verifyDailySummaryActionPrecision()
            try await verifySummaryModelReview()
            try await verifyDailySummaryPersistenceAndDeletion()
            try verifyStructuredDailySummaryItems()
            try await verifyMemoryGovernanceDeletionAndRestore()
            try await verifySuppressionLearning()
            try verifyPersonalIntelligenceConsolidation()
            try verifyConcreteDailySummarySubjects()
            try verifyInsightFeedbackLearning()
            try await verifyIntelligencePersistenceAndFTS()
            try verifyBackwardCompatibleIntelligenceState()
            try await verifyNotificationHostGuard()
            try await verifyCapturePipeline()
            try verifyConversationContextCompression()
            try verifyTypewriterSequence()
            try await verifyPersistence()
            try await verifyCustomModelConfigurationPersistence()
            try await verifyMiniMaxAuthenticationHeaders()
            try await verifyTodayQuestionUsesTimeline()
            try await verifySevenDayOverviewCoverage()
            try await verifyDailySummaryQuestionRetrieval()
            try await verifyChatCommands()
            try await verifyConversationClearRace()
            try await verifyQuestionPersistsBeforeModelFailure()
            try await verifyLocalAnswer()
            if CommandLine.arguments.contains("--live-anthropic") {
                try await verifyLiveAnthropicCompatibility()
                print("PASS: RecallVerifier completed 61 checks, including live Anthropic compatibility.")
            } else {
                print("PASS: RecallVerifier completed 74 integration checks.")
            }
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func verifyMatterFilesAndReview() throws {
        let now = Date.now
        let old = Calendar.current.date(byAdding: .day, value: -12, to: now)!
        let first = CaptureRecord(eventTemplate: .manualMoment, createdAt: old, contentHash: "matter-a", ocrText: "[聊天·自己] 账单导出问题已定位，需要检查分页边界。")
        let second = CaptureRecord(eventTemplate: .manualMoment, createdAt: now, contentHash: "matter-b", ocrText: "[聊天·自己] 账单导出修复已验证通过。")
        func episode(_ record: CaptureRecord, status: WorkEpisodeStatus) -> WorkEpisode {
            WorkEpisode(day: record.createdAt, startedAt: record.createdAt, endedAt: record.createdAt,
                projectKey: "billing-export", projectName: "账单导出修复", title: "账单导出修复",
                intent: "修复分页边界", action: record.ocrText, outcome: status == .completed ? "账单导出修复已验证通过" : nil,
                status: status, importance: 0.8, confidence: 0.9, sourceApps: ["测试应用"], evidenceIDs: [record.id])
        }
        var state = RecallState(captures: [first, second], episodes: [episode(first, status: .progressed), episode(second, status: .completed)])
        let engine = MatterMemoryEngine()
        let files = engine.files(in: state)
        try expect(files.count == 1 && files[0].events.count == 2, "事情档案应跨天串联同一具体主题")
        try expect(files[0].latest.status == .completed && files[0].latest.eventAt == nil, "不得默认将采集时间确认为发生时间")
        let weekly = engine.weeklyReview(files: files, endingAt: now)
        try expect(weekly.count == 1 && weekly[0].previous != nil && weekly[0].changes.count == 1, "周回顾应对照更早状态，且只展示本周变化")
        state.matterCorrections = [MatterCorrection(evidenceIDs: [second.id], kind: .separate, text: "另一份报表修复")]
        try expect(engine.files(in: state).count == 2, "用户拆分应优先于自动归类")
        state.matterCorrections = [MatterCorrection(evidenceIDs: [second.id], kind: .eventDate, eventAt: old)]
        try expect(engine.weeklyReview(files: engine.files(in: state), endingAt: now).isEmpty, "发生时间更正应影响周回顾")
        state.matterCorrections = []
        state.captures.removeAll { $0.id == second.id }
        try expect(engine.files(in: state).first?.events.count == 1, "已删除来源不得继续出现在档案")
        state.captures = []
        try expect(engine.files(in: state).isEmpty, "没有证据时不得生成档案或回顾")
    }

    private static func verifyMatterEvidenceQuality() throws {
        let engine = MatterMemoryEngine()
        let now = Date.now
        let old = now.addingTimeInterval(-86400 * 12)
        func capture(_ text: String, at date: Date? = nil, title: String = "账单导出修复", owned: Bool = false) -> CaptureRecord {
            CaptureRecord(eventTemplate: .manualMoment, createdAt: date ?? now, sourceAppName: "测试浏览器", windowTitle: title,
                contentHash: UUID().uuidString, ocrText: text, summary: "过期摘要；错误片段与旧状态", textOrigin: owned ? .userInput : .screenOCR)
        }
        func episode(_ record: CaptureRecord, name: String = "账单导出修复") -> WorkEpisode {
            WorkEpisode(day: record.createdAt, startedAt: record.createdAt, endedAt: record.createdAt,
                projectKey: "window:" + name, projectName: name, title: name, intent: "旧主题推断",
                action: "xx|旧摘要", outcome: "完成更新", nextAction: "下一步是修复", status: .completed,
                importance: 0.9, confidence: 0.9, sourceApps: [], evidenceIDs: [record.id])
        }
        let noise = [
            capture("xx | 标签页 × 完成更新", title: "Google"),
            capture("https://example.test/search?q=sample&lang=zh\n有新版浏览器可用", title: "搜索结果"),
            capture("已定位原因，正在实施修复。", title: "某工具的开发者和应用"),
            capture("[聊天·对方] 账单导出修复已验证通过。"),
            capture("[聊天·角色未知] 账单导出修复已验证通过。"),
            capture("教程：完成账单导出修复后，可以返回应用。"),
            capture("[聊天·自己] 如果账单导出修复测试通过，就可以发布。"),
            capture("[聊天·自己] 下一步是修复。"),
            capture("[聊天·自己] public func fixExport() { return result }"),
            capture("[聊天·自己] 明天准备修复账单导出，测试通过后提交。")
        ]
        let bad = RecallState(captures: noise, episodes: noise.map { episode($0, name: $0.windowTitle!) })
        try expect(engine.files(in: bad).isEmpty, "工具网页、文章、未知角色、助手结果、条件句、代码和泛指修复不能变成我的事项")

        let working = capture("[聊天·自己] 账单导出修复正在验证分页边界。", at: old)
        let done = capture("[聊天·自己] 账单导出修复已验证通过，分页边界也通过了回归测试。\n[聊天·自己] 库存同步仍然失败。")
        let state = RecallState(captures: [working, done], episodes: [episode(working), episode(done)])
        let files = engine.files(in: state)
        try expect(files.count == 2, "同一截图中的两个真实事项都必须保留")
        let bill = files.first { $0.title == "账单导出修复" }!
        try expect(bill.events.count == 2, "可归属的具体工作应保留完整过程")
        try expect(bill.latest.detail == "账单导出修复已验证通过，分页边界也通过了回归测试。", "摘要必须取原始完整句，不沿用旧截断摘要或拼接无关句子")
        try expect(bill.latest.status == .completed, "同一截图里其他事情失败，不能污染当前事情状态")
        try expect(engine.weeklyReview(files: [bill], endingAt: now).first?.previous?.status == .progressed, "周回顾应展示正确的先前状态")

        let longText = "账单导出修复已验证通过，" + String(repeating: "分页边界与空数据场景均有回归记录，", count: 14) + "结果已归档。"
        let longCapture = capture("[聊天·自己] " + longText)
        let full = engine.files(in: RecallState(captures: [longCapture], episodes: [episode(longCapture)]))
        try expect(full.first?.latest.detail == longText, "正文超过旧摘要字数限制时仍应保留完整原句")

        let recovered = capture("[聊天·自己] 账单导出修复已验证通过。", title: "Google")
        let repaired = engine.files(in: RecallState(captures: [recovered], episodes: [episode(recovered, name: "Google")]))
        try expect(repaired.first?.title == "账单导出修复", "旧工具标题应从清晰原文重新识别具体事项")
        let fresh = engine.files(in: RecallState(captures: [recovered]))
        try expect(fresh.first?.title == repaired.first?.title, "新旧记录必须经过同一质量校验")

        let before = capture("[聊天·自己] 账单导出修复已验证通过。", at: old)
        let repeatCapture = capture(before.ocrText)
        let repeated = engine.files(in: RecallState(captures: [repeatCapture, before], episodes: [episode(repeatCapture), episode(before)]))
        try expect(repeated.first?.events.count == 1 && repeated.first?.evidenceIDs.count == 2, "重复截图合并来源，不重复创建进展")
        try expect(engine.weeklyReview(files: repeated, endingAt: now).isEmpty, "重看旧结果不应算成本周新变化")
        let reopened = capture("[聊天·自己] 账单导出修复仍然失败。", at: now.addingTimeInterval(10))
        let history = engine.files(in: RecallState(captures: [before, reopened], episodes: [episode(before), episode(reopened)]))
        try expect(history.first?.latest.status == .blocked, "后续明确失败应替代旧的已完成状态")

        let input = capture("明天需要提交账单导出修复。", owned: true)
        let pending = engine.files(in: RecallState(captures: [input], episodes: [episode(input)]))
        try expect(pending.first?.latest.status == .pending, "明确的用户输入待办应保留")
        var corrected = bad
        corrected.matterCorrections = [MatterCorrection(evidenceIDs: [noise[3].id], kind: .separate, text: "账单导出参考方案")]
        let neutral = engine.files(in: corrected)
        try expect(neutral.count == 1 && neutral[0].latest.status == .explored, "用户主动归档的他人资料不能升级为本人已完成")
        try expect(engine.weeklyReview(files: neutral, endingAt: now).isEmpty, "归档参考资料不能伪装成本周工作进展")
    }

    private static func verifyMatterProgressQualityAndFreshness() throws {
        let engine = MatterMemoryEngine()
        let now = Date.now
        let old = now.addingTimeInterval(-20 * 86400)
        let name = "Orion 发票导出"
        func capture(_ text: String, title: String = "Orion 发票导出", at: Date? = nil) -> CaptureRecord {
            CaptureRecord(eventTemplate: .manualMoment, createdAt: at ?? now, sourceAppName: "合成测试窗口",
                windowTitle: title, contentHash: UUID().uuidString, ocrText: text, textOrigin: .screenOCR)
        }
        func episode(_ record: CaptureRecord) -> WorkEpisode {
            WorkEpisode(day: record.createdAt, startedAt: record.createdAt, endedAt: record.createdAt,
                projectKey: "synthetic-topic", projectName: record.windowTitle ?? name,
                title: "旧的截断标题", intent: "旧状态不可信", action: "旧摘要", nextAction: "继续处理",
                status: .pending, importance: 0.8, confidence: 0.9, sourceApps: [], evidenceIDs: [record.id])
        }
        // Entirely synthetic examples; no uploaded OCR or personal data in the verifier.
        let noise = [
            capture("[聊天·自己] 正在编写程序代码。", title: "程序代码"),
            capture("[聊天·自己] 完成以前需要很多部门才能承担的工作。", title: "以前需要很多部门才能承担的工作"),
            capture("[聊天·自己] ③再试两回仍然失败，然后重新登录。", title: "③再试两回"),
            capture("[聊天·自己] 每个人都应该完成自己的计划。", title: "自己的计划"),
            capture("[聊天·自己] 先打开 Orion 控制台，失败后重新启动。", title: "Orion 控制台"),
            capture("[聊天·自己] 我准备开发 Orion 发票导出，验证通过后再发布。"),
            capture("[聊天·自己] 文章案例：Orion 发票导出正在开发。"),
            capture("[聊天·角色未知] Orion 发票导出已定位游标偏移。")
        ]
        try expect(engine.files(in: RecallState(captures: noise, episodes: noise.map(episode))).isEmpty,
            "泛指代码、文章观点、编号操作步骤和未确认意向不能因关键词变成进行中事项")
        try expect(engine.files(in: RecallState(captures: noise)).isEmpty, "新记录和历史 Episode 必须使用相同质量检查")

        let progressText = "Orion 发票导出已定位游标偏移。"
        let actionText = "明天需要修复 Orion 发票导出的页码换算。"
        let context = capture("[聊天·自己] " + progressText + "\n[聊天·自己] " + actionText
            + "\n[聊天·自己] Nova 图像压缩仍然失败。")
        let combined = engine.files(in: RecallState(captures: [context], episodes: [episode(context)]))
        try expect(combined.count == 2, "同屏不同主题必须分别保留")
        let orion = combined.first { $0.title == name }!
        try expect(orion.latest.detail == progressText && orion.latest.nextAction == actionText,
            "同一来源的进展与后续行动应分开保留，后面的待办不能覆盖前面的实际进展")
        try expect(orion.latest.status == .progressed, "已定位的进展不能被后面的待办降为单纯待办")
        try expect(orion.evidenceIDs == [context.id], "进展和行动必须有真实关联来源")

        let first = capture("[聊天·自己] " + progressText, at: old)
        let next = capture("[聊天·自己] " + actionText)
        var state = RecallState(captures: [first, next], episodes: [episode(first), episode(next)])
        let paired = engine.files(in: state)[0]
        try expect(paired.resumeText == progressText && paired.resumeNextAction == actionText,
            "跨记录接续应同时找回上次进展和最新明确行动")
        try expect(!paired.needsStatusUpdate(at: now), "新行动应使主题回到近期接续列表")
        state.captures.removeAll { $0.id == next.id }
        let deletedAction = engine.files(in: state)[0]
        try expect(deletedAction.resumeNextAction == nil && deletedAction.needsStatusUpdate(at: now),
            "删除后续来源应撤掉对应行动，旧进展不能冒充近期更新")

        let repeatCapture = capture(first.ocrText)
        let repeated = engine.files(in: RecallState(captures: [first, repeatCapture], episodes: [episode(first), episode(repeatCapture)]))[0]
        try expect(repeated.events.count == 1 && repeated.needsStatusUpdate(at: now), "重新截到同一旧进展不能刷新进行中状态")
        let resultText = "Orion 发票导出已验证通过。"
        let resultThenAction = capture("[聊天·自己] " + resultText + "\n[聊天·自己] " + actionText)
        let open = engine.files(in: RecallState(captures: [resultThenAction], episodes: [episode(resultThenAction)]))[0]
        try expect(open.latest.status == .pending && open.latest.detail == resultText && open.resumeNextAction == actionText,
            "已经验证且仍有明确后续行动时，应保留结果和未闭环行动")
        let done = capture("[聊天·自己] Orion 发票导出已发布。", at: now.addingTimeInterval(1))
        let closed = engine.files(in: RecallState(captures: [resultThenAction, done], episodes: [episode(resultThenAction), episode(done)]))[0]
        try expect(closed.latest.status == .completed && closed.resumeNextAction == nil, "新的完成证据应关闭历史行动")
        let frontend = capture("[聊天·自己] 前端账单检索已定位缓存键冲突。", title: "前端账单检索")
        try expect(engine.files(in: RecallState(captures: [frontend], episodes: [episode(frontend)])).first?.latest.status == .progressed,
            "过滤不完整前后缀时不能误删真实的前端、后端主题")
        let commitment = capture("[聊天·自己] 明天提交 Orion 发票导出回归报告。")
        try expect(engine.files(in: RecallState(captures: [commitment], episodes: [episode(commitment)])).first?.latest.status == .pending,
            "有具体对象的本人明确时间安排应保留")
        let blocking = capture("[聊天·自己] Orion 发票导出卡住了，联调权限尚未开放。")
        try expect(engine.files(in: RecallState(captures: [blocking], episodes: [episode(blocking)])).first?.latest.status == .blocked,
            "有明确对象的真实阻碍不能与泛指重试步骤一起被过滤")
        for title in ["文章翻译工作流", "返回按钮修复", "重试链路回滚"] {
            let realWork = capture("[聊天·自己] " + title + "已验证通过。", title: title)
            try expect(engine.files(in: RecallState(captures: [realWork], episodes: [episode(realWork)])).first?.latest.status == .completed,
                "观点和操作词的过滤不能误删具体事项：" + title)
        }

        let manualOld = try ManualMatterNote(title: "Orion 发票导出", detail: "等待联调排期。", status: .blocked, eventAt: old).capture(recordedAt: old)
        let manualNow = try ManualMatterNote(title: "Orion 发票导出", detail: "等待联调排期。", status: .blocked, eventAt: now).capture(recordedAt: now)
        let reaffirmed = engine.files(in: RecallState(captures: [manualOld, manualNow]))[0]
        try expect(reaffirmed.events.count == 2 && !reaffirmed.needsStatusUpdate(at: now),
            "用户明确补记同一状态是新的确认，不能当作重复截图丢弃")
        try expect(context.ocrText.contains(progressText) && first.ocrText == "[聊天·自己] " + progressText,
            "重建摘要不能改写原始来源")
    }

    private static func verifyExperienceAndQuestionSelection() throws {
        let old = CaptureRecord(eventTemplate: .manualMoment, createdAt: Date.now.addingTimeInterval(-86400 * 15), contentHash: "old-method", ocrText: "账单导出：分页边界修复验证通过", summary: "账单导出")
        let latest = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, contentHash: "new-state", ocrText: "账单导出新格式仍在验证", summary: "账单导出")
        var duplicate = old
        duplicate.id = UUID()
        let selected = MemoryEvidenceSelector().select([latest, duplicate, old], question: "账单导出后来进展怎样", limit: 5)
        try expect(selected.count == 2, "相同截图文本不得挤占检索证据")
        try expect(selected.first?.ocrText == old.ocrText && selected.last?.id == latest.id, "状态问题需要同时保留早期和最新来源")
        try expect(MemoryQuestionIntent(question: "上次怎么解决账单导出") == .solution, "问题意图应区分历史经验")
        try expect(MemoryQuestionIntent(question: "最近七天做了哪些事情") == .overview, "问题意图应识别跨日回顾")
        let past = MatterEvent(id: old.id, title: "账单导出", detail: old.ocrText, recordedAt: old.createdAt, status: .completed, evidenceIDs: [old.id])
        let current = MatterEvent(id: latest.id, title: "账单导出", detail: latest.ocrText, recordedAt: latest.createdAt, status: .progressed, evidenceIDs: [latest.id])
        let file = MatterFile(id: "export", title: "账单导出", events: [past, current])
        let hints = MatterMemoryEngine().experiences(for: file, in: [file])
        try expect(hints.count == 1 && hints[0].past.id == old.id, "经验提示必须回到独立的历史结果")
        let unrelated = MatterFile(id: "travel", title: "旅行住宿", events: [current])
        try expect(MatterMemoryEngine().experiences(for: unrelated, in: [file]).isEmpty, "无具体共同主题不得强行联想")
    }

    private static func verifyMatterCorrectionPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Recall-Matter-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let record = CaptureRecord(eventTemplate: .taskCommitment, contentHash: "correction-test", ocrText: "[聊天·自己] 提醒我明天提交账单导出修复。")
        try await store.addCapture(record)
        let reminder = ReminderCandidate(title: "提交账单导出修复", detail: "测试", dueAt: .now, sourceCaptureIDs: [record.id], confidence: 0.9)
        try await store.updateReminder(reminder)
        let correction = MatterCorrection(evidenceIDs: [record.id], kind: .completed, text: "账单导出修复")
        try await store.saveMatterCorrection(correction)
        try await store.setExperienceHints(enabled: true)
        try await store.dismissExperience(id: "test-hint")
        let reloaded = try FileMemoryStore(storage: storage)
        let state = await reloaded.snapshot()
        try expect(state.captures.first?.ocrText == record.ocrText, "纠错不能改写原始证据")
        try expect(state.reminders.first?.status == .completed, "用户标记完成应同步关闭关联提醒")
        try expect(state.experienceHintsEnabled && state.dismissedExperienceIDs == ["test-hint"], "经验提示开关和忽略必须持久化")
        let projected = state.correctedForAnalysis()
        try expect(projected.captures.first?.ocrText.contains("已完成") == true, "重新分析应使用用户完成更正")
        try expect(ReminderExtractor().candidates(from: projected.captures, existing: []).isEmpty, "已完成来源不能重新生成待办")
        try await reloaded.saveMatterCorrection(MatterCorrection(evidenceIDs: [record.id], kind: .notMine))
        let excluded = await reloaded.snapshot().correctedForAnalysis()
        try expect(excluded.captures.isEmpty, "错归属来源应停止进入推断和检索")
        let transaction = try await reloaded.moveCapturesToRecentlyDeleted(ids: [record.id], reason: .noLongerNeeded, suppressSimilar: false)
        let deleted = await reloaded.snapshot()
        try expect(deleted.matterCorrections.isEmpty && transaction?.matterCorrections?.count == 2, "删除来源时纠错内容应随之移入最近删除")
        if let transaction { _ = try await reloaded.restoreRecentlyDeleted(id: transaction.id) }
        let restored = await reloaded.snapshot()
        try expect(restored.matterCorrections.count == 2, "恢复来源应恢复纠错，不能复活错误推断")
        try await reloaded.clearAllMemoryData()
        let cleared = await reloaded.snapshot()
        try expect(cleared.matterCorrections.isEmpty && cleared.dismissedExperienceIDs.isEmpty, "清空记忆不能残留纠错内容")
        let legacy = try JSONDecoder().decode(RecallState.self, from: Data("{}".utf8))
        try expect(legacy.matterCorrections.isEmpty && !legacy.experienceHintsEnabled, "旧数据应安全迁移且默认不主动提示")
    }

    private static func verifyManualMatterLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Recall-ManualMatter-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let now = Date.now
        let yesterday = now.addingTimeInterval(-86400)
        let first = try await store.addManualMatter(ManualMatterNote(title: "  账单导出修复  ",
            detail: "等待联调环境。", status: .blocked, eventAt: yesterday), now: now)
        let second = try await store.addManualMatter(ManualMatterNote(title: "账单导出修复",
            detail: "已交付验收结果。", status: .completed, eventAt: now), now: now.addingTimeInterval(1))
        let neutral = try await store.addManualMatter(ManualMatterNote(title: "周末旅行备忘",
            detail: "湖边路线", status: .explored, eventAt: now), now: now)
        let reloaded = try FileMemoryStore(storage: storage)
        let state = await reloaded.snapshot()
        let engine = MatterMemoryEngine()
        let files = engine.files(in: state)
        try expect(files.count == 2, "手动记录应立即进入档案，无需先生成每日总结")
        let file = files.first { $0.title == "账单导出修复" }!
        try expect(file.events.count == 2 && file.latest.status == .completed, "同名手动记录应跨日期串联并使用用户明确状态")
        // The store's ISO8601 representation preserves seconds, not subsecond precision.
        let firstEvent = file.events[0]
        try expect(abs((firstEvent.eventAt ?? .distantPast).timeIntervalSince(yesterday)) < 1
            && abs(firstEvent.recordedAt.timeIntervalSince(now)) < 1, "补记应区分发生时间与记录时间")
        try expect(file.latest.detail == "已交付验收结果。" && file.latest.evidenceIDs == [second.id], "手动原文和可追溯来源应完整保留")
        try expect(engine.weeklyReview(files: files, endingAt: now.addingTimeInterval(2)).count == 1, "仅作记录不应虚构进行中事项或周进展")
        try expect(state.reminders.isEmpty && first.imageRelativePath == nil && state.matterCorrections.isEmpty, "手动补记不应截图、创建通知或冒充用户纠错")
        let invalid = ManualMatterNote(title: "!!!", detail: "", status: .pending, eventAt: now)
        do {
            _ = try await reloaded.addManualMatter(invalid, now: now)
            throw VerificationError.failed("无效输入不应保存")
        } catch is VerificationError { throw VerificationError.failed("无效输入不应保存") }
        catch { }
        do {
            _ = try await reloaded.addManualMatter(ManualMatterNote(title: "未来时间测试", detail: "备忘", status: .explored, eventAt: now.addingTimeInterval(3600)), now: now)
            throw VerificationError.failed("不能补记未来发生的进展")
        } catch is VerificationError { throw VerificationError.failed("不能补记未来发生的进展") }
        catch { }
        let afterInvalid = await reloaded.snapshot()
        try expect(afterInvalid.captures.count == 3, "校验失败不应留下半条记录")
        try await reloaded.saveMatterCorrection(MatterCorrection(evidenceIDs: [first.id], kind: .inaccurate))
        let afterInaccurate = await reloaded.snapshot()
        try expect(engine.files(in: afterInaccurate).first { $0.title == file.title }?.events.count == 1, "手动补记也必须遵守内容纠错排除")
        try await reloaded.saveMatterCorrection(MatterCorrection(evidenceIDs: [neutral.id], kind: .completed, text: "周末旅行备忘"))
        let afterCompleted = await reloaded.snapshot()
        try expect(engine.files(in: afterCompleted).first { $0.title == "周末旅行备忘" }?.latest.status == .completed, "用户完成更正应覆盖手动初始状态")
        let deleted = try await reloaded.moveCapturesToRecentlyDeleted(ids: [first.id, second.id], reason: .noLongerNeeded, suppressSimilar: false, now: now)
        let afterDeleted = await reloaded.snapshot()
        try expect(!engine.files(in: afterDeleted).contains { $0.title == file.title }, "删除来源应同步移除手动档案")
        if let deleted { _ = try await reloaded.restoreRecentlyDeleted(id: deleted.id, now: now.addingTimeInterval(1)) }
        let afterRestored = await reloaded.snapshot()
        try expect(engine.files(in: afterRestored).contains { $0.title == file.title }, "期限内恢复来源应恢复手动档案")
        let data = try JSONEncoder().encode(first)
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "manualMatter")
        let old = try JSONDecoder().decode(CaptureRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        try expect(old.manualMatter == nil, "旧采集记录缺少手动事项字段时仍应可读取")
        var settings = PrivacySettings()
        settings.cloudUseEnabled = true
        try expect(PrivacyEngine().cloudContext(from: [first], settings: settings).first?.manualMatter == nil, "云端上下文不能保留未经脱敏的手动记录副本")
    }

    private static func verifyDefaultEventTemplates() throws {
        let rules = EventRule.defaults()
        try expect(rules.count == 9, "应提供 9 个事件模板")
        try expect(Set(rules.map(\.template)) == Set(CaptureEventTemplate.allCases), "事件模板集合不完整")
        try expect(rules.contains(where: { $0.template == .manualMoment && $0.isEnabled }), "手动记录此刻应默认启用")
        try expect(rules.contains(where: { $0.template == .enterKeyTrigger && !$0.isEnabled }), "Enter 键触发记录必须默认关闭")
        try expect(rules.first(where: { $0.template == .manualMoment })?.participatesInReminders == true, "手动记录应默认参与提醒发现")
        try expect(rules.first(where: { $0.template == .dailyReview })?.participatesInReminders == false, "每日总结不应被再次扫描并产生重复提醒")
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

    private static func verifyLocalSummaryNoiseFiltering() throws {
        let text = """
        [聊天·对方] 2 chatgpt.com
        [聊天·对方] C New chat
        [聊天·自己] 登录
        [聊天·角色未知] 9:39
        [聊天·对方] 评估服务的生产就绪性，需要核对事务一致性和证据化查询
        [聊天·自己] 下一步完成只读接口的权限校验
        [聊天·自己] 下一步完成只读接口的权限校验
        """
        let summary = LocalSummary.make(from: text) ?? ""
        try expect(summary.contains("事务一致性") && summary.contains("权限校验"), "摘要没有保留有效正文")
        try expect(!summary.contains("聊天·") && !summary.contains("chatgpt.com") && !summary.contains("New chat"), "摘要仍混入角色标记或界面噪声")
        try expect(summary.components(separatedBy: "权限校验").count == 2, "摘要没有去重")
        let tags = LocalSummary.tags(from: text)
        try expect(!tags.contains(where: { ["聊天", "对方", "自己", "com", "chatgpt", "登录"].contains($0.lowercased()) }), "标签仍包含界面或角色噪声")
        try expect(LocalSummary.make(from: "ChatGPT - chat.openai.com; ChatGPT - chatgpt.com\n•；•\n09:39\n登录") == nil, "纯界面噪声不应生成伪摘要")
        let linkText = "需要核对设计文档 https://example.com/design 并完成权限校验"
        try expect(LocalSummary.make(from: linkText)?.contains("权限校验") == true, "清理网址误删了同一行的有效内容")
        try expect(LocalSummary.make(from: linkText)?.contains("example.com") == false, "正文中的网址没有清理")
        let longText = "完成验证：" + String(repeating: "事务一致性与权限校验", count: 40)
        let bounded = LocalSummary.make(from: longText) ?? ""
        try expect(bounded.count == 240 && bounded.hasSuffix("…"), "长摘要没有在限制内明确显示省略")
    }

    private static func verifyCapturePresentation() throws {
        let raw = "[聊天·对方] chatgpt.com\n[聊天·自己] 完成退款幂等设计，下一步核对重复请求的处理结果"
        var capture = makeCapture(text: raw, app: "Google Chrome")
        capture.eventTemplate = .enterKeyTrigger
        capture.summary = "[聊天·对方] chatgpt.com"
        capture.tags = ["聊天", "自己", "com"]
        let presentation = CapturePresentation(capture: capture)
        try expect(presentation.title.contains("退款幂等"), "旧记录仍以触发方式或旧摘要作为标题")
        try expect(!presentation.summary.contains("chatgpt.com") && !presentation.summary.contains("聊天·"), "旧记录没有使用新摘要规则")
        try expect(capture.ocrText == raw && capture.summary == "[聊天·对方] chatgpt.com", "展示转换改写了原始证据或旧状态")
        capture.ocrText = "chatgpt.com\n登录\n9:39"
        capture.windowTitle = "ChatGPT - chatgpt.com"
        let noiseOnly = CapturePresentation(capture: capture)
        try expect(noiseOnly.title == "Google Chrome的记录" && noiseOnly.summary.contains("未提取到清晰正文"), "噪声记录没有准确的回退说明")
        capture.ocrText = ""
        capture.summary = nil
        capture.windowTitle = "季度产品设计评审"
        let empty = CapturePresentation(capture: capture)
        try expect(empty.title == "季度产品设计评审" && empty.summary.contains("未识别出文本"), "空 OCR 没有使用可读窗口标题回退")
        capture.summary = "完成历史记录迁移"
        try expect(CapturePresentation(capture: capture).title == "完成历史记录迁移", "仅有摘要的兼容记录无法展示")
    }

    private static func verifyConversationRoleRecognition() throws {
        let lines = [
            PositionedTextLine(text: "请明天回复报价", boundingBox: CGRect(x: 0.04, y: 0.7, width: 0.55, height: 0.08)),
            PositionedTextLine(text: "好的，我上午处理", boundingBox: CGRect(x: 0.47, y: 0.5, width: 0.49, height: 0.08)),
            PositionedTextLine(text: "昨天 18:30", boundingBox: CGRect(x: 0.46, y: 0.4, width: 0.08, height: 0.04))
        ]
        let roleLayout = ConversationOCRLayout(contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1), bubbles: [
            ConversationBubble(bounds: lines[0].boundingBox, speaker: .other),
            ConversationBubble(bounds: lines[1].boundingBox, speaker: .user)
        ])
        let conversation = ConversationOCRFormatter.format(lines, context: .messaging, layout: roleLayout)
        try expect(conversation.contains("[聊天·对方] 请明天回复报价"), "聊天左侧内容没有标记为对方")
        try expect(conversation.contains("[聊天·自己] 好的，我上午处理"), "聊天右侧内容没有标记为自己")
        try expect(conversation.contains("[聊天·角色未知] 昨天 18:30"), "聊天中部内容不应强行归属角色")

        let document = ConversationOCRFormatter.format(lines, context: .document)
        try expect(!document.contains("[聊天·"), "普通文档 OCR 不应添加聊天角色")

        let capture = makeCapture(text: "[聊天·对方] 我喜欢每天开会\n[聊天·自己] 我不喜欢没有结论的会议", app: "微信")
        let consolidation = PersonalIntelligenceEngine().consolidate(day: capture.createdAt, records: [capture])
        let memories = consolidation.memories.map(\.content).joined(separator: "\n")
        try expect(!memories.contains("我喜欢每天开会"), "对方的话被错误写入用户长期记忆")
        try expect(memories.contains("我不喜欢没有结论的会议"), "用户自己说的话没有进入长期记忆")
    }

    private static func verifyConversationRegionRecognition() throws {
        // Only synthetic pixels and invented text. Coordinates below are top-left pixels;
        // Vision's observations and the production layout use normalized bottom-left bounds.
        let width = 800, height = 600, right = 780
        func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGRect {
            CGRect(x: Double(x) / Double(width), y: 1 - Double(y + h) / Double(height),
                   width: Double(w) / Double(width), height: Double(h) / Double(height))
        }
        func line(_ text: String, _ x: Int, _ y: Int, _ w: Int = 120, _ h: Int = 16) -> PositionedTextLine {
            PositionedTextLine(text: text, boundingBox: box(x, y, w, h))
        }
        for dark in [true, false] {
            for left in [0, 240, 330] {
                let background: UInt8 = dark ? 32 : 238
                var pixels = [UInt8](repeating: 255, count: width * height * 4)
                func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: [UInt8]) {
                    for row in y..<(y + h) {
                        for column in x..<(x + w) {
                            let index = (row * width + column) * 4
                            pixels[index] = color[0]; pixels[index + 1] = color[1]; pixels[index + 2] = color[2]
                        }
                    }
                }
                fill(0, 0, width, height, [background, background, background])
                if left > 0 {
                    fill(0, 0, left, height, dark ? [20, 20, 20] : [210, 210, 210])
                    fill(left - 1, 0, 1, height, [100, 100, 100])
                    fill(15, 150, left - 35, 25, [150, 150, 150]) // sidebar preview
                }
                fill(right, 0, width - right, height, dark ? [12, 12, 12] : [255, 255, 255])
                fill(left, 60, right - left, 1, [100, 100, 100])
                fill(left, 440, right - left, 1, [100, 100, 100])
                let otherX = left + max(40, (right - left) / 12)
                fill(otherX, 125, 320, 70, dark ? [66, 66, 66] : [255, 255, 255])
                let selfX = left + (right - left) / 6
                fill(selfX, 270, right - 40 - selfX, 70, [30, 125, 220])
                fill(right - 70, 355, 30, 25, [30, 125, 220])
                fill(left + 8, 125, 24, 24, [180, 90, 70]) // other avatar
                fill(right - 30, 270, 24, 24, [180, 90, 70]) // self avatar
                guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                      let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                      let layout = ConversationImageLayout.detect(in: image) else {
                    throw VerificationError.failed("未识别合成聊天正文区，深色=\(dark)，侧栏=\(left)")
                }
                try expect(abs(layout.contentBounds.minX - CGFloat(left) / CGFloat(width)) < 0.01,
                           "聊天正文边界未适应不同侧栏宽度")
                try expect(layout.contentBounds.maxY < 0.91 && layout.contentBounds.minY > 0.25,
                           "聊天正文未排除标题和输入区，或上下坐标翻转")
                var lines = [
                    line("窗口标题", left + 100, 25),
                    line("明天会议确认后回复", otherX + 10, 135, 240),
                    line("待办已核对", otherX + 10, 165, 180),
                    line("昨天 18:30", left + (right - left) / 2 - 40, 225, 80),
                    line("我已完成账单导出", selfX + 10, 280, 200),
                    line("分页验证也通过了", selfX + 10, 310, 200),
                    line("好", right - 65, 360, 18),
                    line("未找到气泡的正文", left + 90, 400),
                    line("快速会议", left + 100, 500)
                ]
                if left > 0 { lines += [line("邮件 工作台 通讯录", 15, 155, left - 35)] }
                // Shuffle observations: ordering is based on bubble/line geometry.
                let text = ConversationOCRFormatter.format(Array(lines.reversed()), context: .messaging, layout: layout)
                try expect(!text.contains("工作台") && !text.contains("窗口标题") && !text.contains("快速会议"),
                           "侧栏、标题或输入区仍进入聊天 OCR")
                try expect(text.contains("[聊天·对方] 明天会议确认后回复 待办已核对"),
                           "对方长气泡未保持角色，或误删了正文中的菜单同名词")
                try expect(text.contains("[聊天·自己] 我已完成账单导出 分页验证也通过了"),
                           "跨越中线的自己长气泡或换行归属错误")
                try expect(text.contains("[聊天·自己] 好"), "短消息气泡被遗漏")
                try expect(text.contains("[聊天·角色未知] 昨天 18:30"), "聊天时间未作为中立上下文保留")
                try expect(text.contains("[聊天·角色未知] 未找到气泡的正文"), "未识别气泡的正文应保留且角色未知")
                try expect(text.range(of: "明天会议")!.lowerBound < text.range(of: "我已完成")!.lowerBound,
                           "消息未按上下顺序排列")
            }
        }
        let uncertain = [line("需要处理报告", 450, 120)]
        let fallback = ConversationOCRFormatter.format(uncertain, context: .messaging)
        try expect(fallback == "[聊天·角色未知] 需要处理报告", "无法定位原生聊天区时不应按整图中线猜角色")
        try expect(ConversationOCRFormatter.format(uncertain, context: .document) == "需要处理报告", "文档模式受到聊天过滤影响")
        var flatPixels = [UInt8](repeating: 238, count: width * height * 4)
        for index in stride(from: 3, to: flatPixels.count, by: 4) { flatPixels[index] = 255 }
        let provider = CGDataProvider(data: Data(flatPixels) as CFData)!
        let flat = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        try expect(ConversationImageLayout.detect(in: flat) == nil, "没有结构证据的图像不应猜测聊天裁剪区")
    }

    private static func verifySearch() throws {
        let matching = makeCapture(text: "和产品团队讨论 Recall 的 OCR 质量与会议摘要", app: "Notes")
        let unrelated = makeCapture(text: "今天午餐吃面", app: "Messages")
        let results = MemorySearchEngine().search(MemorySearchQuery(text: "OCR 会议摘要"), in: [unrelated, matching])
        try expect(results.first?.capture.id == matching.id, "搜索没有优先返回相关记录")
        try expect(results.first?.matchedTerms.contains("ocr") == true, "搜索未报告匹配关键词")
    }

    private static func verifyChineseNaturalLanguageSearch() throws {
        let matching = makeCapture(text: "家庭事项：妙妙的 6 岁生日聚会已办，需要整理照片。", app: "Notes")
        let unrelated = makeCapture(text: "完成 Recall 输入框布局调整", app: "Xcode")
        let results = MemorySearchEngine().search(MemorySearchQuery(text: "妙妙什么时候过生日？"), in: [unrelated, matching])
        try expect(results.first?.capture.id == matching.id, "中文自然语言问题没有拆出人物与生日关键词")
        try expect(results.first?.matchedTerms.contains("妙妙") == true, "中文检索没有保留人物实体")
        try expect(results.first?.matchedTerms.contains("生日") == true, "中文检索没有识别问题主题")
    }

    private static func verifyNaturalLanguageTimeRanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 11, minute: 20))!
        let resolver = MemoryTimeRangeResolver()

        let sevenDays = resolver.resolve("我最近七天做了哪些事情？", now: now, calendar: calendar)
        let expectedStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7))!
        try expect(sevenDays?.requestedDayCount == 7, "最近七天没有解析为 7 个本地自然日")
        try expect(sevenDays?.startDate == expectedStart && sevenDays?.endDate == now, "最近七天的起止边界不正确")

        let thirtyDays = resolver.resolve("过去三十天有哪些进展？", now: now, calendar: calendar)
        try expect(thirtyDays?.requestedDayCount == 30, "中文数字时间范围没有被识别")

        guard let previousWeek = resolver.resolve("上周完成了什么？", now: now, calendar: calendar) else {
            throw VerificationError.failed("上周时间范围没有被识别")
        }
        try expect(previousWeek.requestedDayCount == 7 && previousWeek.endDate <= now, "上周没有解析为独立的前一自然周")
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
        let menuNoise = makeCapture(text: "工作台 通讯录 微盘 更多 搜索 智能文档 设计模式", app: "Browser", createdAt: base)
        let ocrNoise = makeCapture(text: "完成 ×|C) col x|S 集况×", app: "Terminal", createdAt: base)
        let commitNoise = makeCapture(text: "最终提交：34cdc34，main CI 构建及21项集成测试全部通过", app: "Terminal", createdAt: base)
        let completed = makeCapture(text: "已完成：明天提交版本发布说明", app: "Notes", createdAt: base)
        let articleAdvice = makeCapture(text: "不要问“今天我要完成多少事”，而要问“我长期到底在构建什么”；截止：2026年9月21日 9:00", app: "Chrome", createdAt: base)
        let vagueFragment = makeCapture(text: "下一步是修复", app: "Orca", createdAt: base)
        let assistantPrompt = makeCapture(text: "生产环境需要登录才能验证，问下你想怎么处理：", app: "Orca", createdAt: base)
        let principleNote = makeCapture(text: "的一条底层原则：Leader 的目标不是完成任务，而是让整个系统稳定完成任务", app: "flomo", createdAt: base)
        let networkError = makeCapture(text: "网络异常，请检查网络后再试", app: "flomo", createdAt: base)
        let knowledgeNote = makeCapture(text: "解释为什么人坐下来却干不了活：脑子同时挂着过去的懊悔、未来的任务、未完成事项", app: "flomo", createdAt: base)
        let publishDate = makeCapture(text: "发布日期：2026年9月18日", app: "Chrome", createdAt: base)
        let completedTranslation = makeCapture(text: "完成 4 篇纯中文完整译文", app: "Chrome", createdAt: base)
        let commitRecord = makeCapture(text: "提交记录：0a92cfcn", app: "Chrome", createdAt: base)

        let candidates = ReminderExtractor().candidates(
            from: [first, duplicate, deadlineOnly, uncertainQuestion, codeNoise, menuNoise, ocrNoise, commitNoise, completed, articleAdvice, vagueFragment, assistantPrompt, principleNote, networkError, knowledgeNote, publishDate, completedTranslation, commitRecord],
            existing: []
        )
        try expect(candidates.count == 1, "提醒精度过滤未排除疑问句、完成态、截止标签、菜单或代码噪声")
        try expect(candidates[0].title == "明天下午3点提交社会心理学调研报告", "提醒标题没有提炼为明确行动")
        try expect(candidates[0].sourceCaptureIDs.count == 2, "重复记录没有合并为同一提醒候选")
        if let dueAt = candidates[0].dueAt {
            let components = calendar.dateComponents([.day, .hour, .minute], from: dueAt)
            try expect(components.day == 9 && components.hour == 15 && components.minute == 0, "提醒时间没有正确识别明天下午3点")
        } else {
            throw VerificationError.failed("明确时间线索没有生成建议提醒时间")
        }

        let report = makeCapture(
            text: "[聊天·自己] 写一篇介绍《社会心理学》的调研报告，需要包含主要内容和产品设计应用",
            app: "Chrome",
            createdAt: base
        )
        let reportCandidate = ReminderExtractor().candidates(from: [report], existing: []).first
        try expect(reportCandidate?.title == "写一篇介绍《社会心理学》的调研报告", "长句提醒没有提炼行动主干")

        let expiry = makeCapture(text: "[聊天·自己] 合同将于2026年9月30日到期", app: "Notes", createdAt: base)
        let expiryCandidate = ReminderExtractor().candidates(from: [expiry], existing: []).first
        try expect(expiryCandidate?.title == "合同将于2026年9月30日到期", "只有日期和到期状态的有效提醒被漏掉")
        try expect(expiryCandidate?.dueAt.map { calendar.component(.day, from: $0) } == 30, "期限事项没有识别出日期")

        let technicalRules = [
            "24 小时过期，用户每天最多登录一次",
            "30 分钟无操作即过期一比‘每天一次’更严",
            "若业务确认要维持每天登录一次的体验，就按 24h/1440min 配置"
        ].map { makeCapture(text: $0, app: "Orca", createdAt: base) }
        let quotedChat = makeCapture(text: "[聊天·对方] 用户 PC 网页提交订单—请求后端【创建支付单】", app: "企业微信", createdAt: base)
        let directRequest = makeCapture(text: "[聊天·对方] 麻烦你明天回复客户关于报价的邮件", app: "企业微信", createdAt: base)
        let precise = ReminderExtractor().candidates(from: technicalRules + [quotedChat, directRequest], existing: [], now: base)
        try expect(precise.count == 1 && precise[0].title.contains("回复客户"), "技术配置或他人陈述被误识别成个人提醒")
    }

    private static func verifyReminderTimeAndRecurrence() throws {
        let calendar = Calendar.current
        let base = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 11, minute: 10))!
        let relative = makeCapture(text: "提醒我3小时后提交报价单", app: "Notes", createdAt: base)
        let chineseTime = makeCapture(text: "待办：明天下午三点半回复客户", app: "Mail", createdAt: base)
        let recurring = makeCapture(text: "[聊天·自己] 每天上午九点检查服务告警", app: "Notes", createdAt: base)
        let candidates = ReminderExtractor().candidates(from: [relative, chineseTime, recurring], existing: [], now: base)

        let relativeDue = candidates.first(where: { $0.title.contains("提交报价单") })?.dueAt
        try expect(abs((relativeDue?.timeIntervalSince(base) ?? 0) - 3 * 3_600) < 1, "相对小时没有转换成准确提醒时间")
        let reply = candidates.first(where: { $0.title.contains("回复客户") })
        let replyParts = reply?.dueAt.map { calendar.dateComponents([.day, .hour, .minute], from: $0) }
        try expect(replyParts?.day == 9 && replyParts?.hour == 15 && replyParts?.minute == 30, "中文半点时间识别错误")
        try expect(candidates.first(where: { $0.title.contains("检查服务告警") })?.recurrence == .daily, "每日重复线索没有形成重复提醒")
    }

    private static func verifyReminderOccurrenceLifecycle() throws {
        let calendar = Calendar.current
        let firstDay = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 10))!
        let extractor = ReminderExtractor()
        let firstCapture = makeCapture(text: "待办：明天上午9点提交周报", app: "Notes", createdAt: firstDay)
        guard var first = extractor.candidates(from: [firstCapture], existing: [], now: firstDay).first else {
            throw VerificationError.failed("没有生成生命周期测试候选")
        }
        first.status = .completed
        first.completedAt = firstDay.addingTimeInterval(86_400)

        let nextCapture = makeCapture(text: "待办：明天上午9点提交周报", app: "Notes", createdAt: firstDay.addingTimeInterval(86_400))
        try expect(extractor.candidates(from: [nextCapture], existing: [first], now: firstDay.addingTimeInterval(86_400)).count == 1, "已完成事项错误阻止了下一次发生")

        var dismissed = first
        dismissed.status = .dismissed
        dismissed.completedAt = nil
        dismissed.dismissedUntil = firstDay.addingTimeInterval(30 * 86_400)
        let suppressed = extractor.candidates(from: [firstCapture], existing: [dismissed], now: firstDay.addingTimeInterval(5 * 86_400))
        try expect(suppressed.isEmpty, "忽略期内仍重复建议同一事项")
        let restored = extractor.merging([first], into: [dismissed], now: firstDay.addingTimeInterval(31 * 86_400))
        try expect(restored.first?.status == .proposed, "忽略期结束后没有恢复可建议状态")
    }

    private static func verifyReminderLearning() throws {
        var profile = ReminderLearningProfile()
        profile.record(.dismissed, semanticKey: "提交周报")
        try expect(profile.confidenceAdjustment(for: "提交周报") < 0, "忽略反馈没有降低同类候选置信度")
        profile.record(.confirmed(hour: 15), semanticKey: "提交周报")
        profile.record(.completed, semanticKey: "提交周报")
        profile.record(.snoozed(hour: 15), semanticKey: "客户回访")
        try expect(profile.preferredHour == 15, "确认与稍后时间没有形成默认提醒时段")

        let legacyJSON = """
        {"id":"00000000-0000-0000-0000-000000000001","title":"旧提醒","detail":"旧数据","sourceCaptureIDs":[],"confidence":0.8,"status":"proposed","createdAt":"2026-09-08T10:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(ReminderCandidate.self, from: Data(legacyJSON.utf8))
        try expect(legacy.origin == .migrated && legacy.recurrence == .none, "旧提醒模型没有安全迁移默认值")
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

        let proposed = ReminderCandidate(title: "待批量忽略", detail: "验证批量忽略只影响候选提醒。", confidence: 0.7, semanticKey: "批量忽略")
        try await reloaded.updateReminder(proposed)
        let dismissedCount = try await reloaded.dismissAllProposedReminders()
        let afterDismissal = await reloaded.snapshot().reminders
        try expect(dismissedCount == 1, "批量忽略应返回实际更新的待确认提醒数量")
        try expect(afterDismissal.first(where: { $0.id == proposed.id })?.status == .dismissed, "待确认提醒没有被批量忽略")
        try expect(afterDismissal.first(where: { $0.id == scheduled.id })?.status == .scheduled, "批量忽略不应影响已安排提醒")
        let afterLearning = await reloaded.snapshot()
        try expect(afterLearning.reminderLearningProfile.confidenceAdjustment(for: proposed.semanticKey) < 0, "批量忽略没有写入本地反馈学习")
    }

    private static func verifyReminderDeletionAndCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let capture = makeCapture(text: "待办：明天提交删除联动测试", app: "Verifier")
        let linked = ReminderCandidate(title: "提交删除联动测试", detail: "测试", sourceCaptureIDs: [capture.id], confidence: 0.9)
        let manual = ReminderCandidate(title: "手动提醒", detail: "保留", sourceCaptureIDs: [], confidence: 1, origin: .manual)
        let checkpoint = ReminderDiscoveryCheckpoint(
            processedCaptureHashes: [capture.id.uuidString: capture.contentHash],
            lastRunAt: .now,
            eligibleRecordCount: 1,
            analyzedRecordCount: 1,
            discoveredCount: 1
        )
        try await store.addCapture(capture)
        try await store.commitReminderDiscovery(reminders: [linked, manual], checkpoint: checkpoint)
        _ = try await store.deleteCapture(id: capture.id)
        let afterDelete = await store.snapshot()
        try expect(afterDelete.reminders.map(\.id) == [manual.id], "删除来源记录没有清理派生提醒，或误删了手动提醒")
        try expect(afterDelete.reminderDiscoveryCheckpoint.processedCaptureHashes[capture.id.uuidString] == nil, "删除来源记录没有清理增量扫描检查点")
        try await store.clearReminderData()
        let cleared = await store.snapshot()
        try expect(cleared.reminders.isEmpty && cleared.reminderDiscoveryCheckpoint.lastRunAt == nil, "清除提醒数据后仍残留提醒或扫描状态")
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
        try expect(generation.actions.contains(where: { $0.title.contains("回复客户") }), "每日总结没有提取明确行动事项")
        try expect(generation.actions.first(where: { $0.title.contains("回复客户") })?.priority == .normal, "仅有时间或较高识别分数不应被标为建议先做")
        try expect(generation.content.contains("今天推进了什么"), "本地每日总结缺少当天进展区块")
        try expect(!generation.briefing.headline.isEmpty && !generation.briefing.progress.isEmpty, "每日总结没有形成结构化工作主线")
        try expect(generation.content.contains("接下来要处理"), "本地每日总结缺少统一行动区块")
        try expect(!generation.content.contains("近 14 天提醒与建议"), "时间筛选范围仍被错误展示为独立内容板块")
        try expect(!generation.content.contains("跟进客户报价"), "历史总结快照中的待办被再次复制到当天行动区块")
        try expect(!generation.content.contains("过期历史待办"), "十四天窗口外的历史总结不应参与聚合")
        let cleaned = DailySummaryContentFormatter.removingCitationMarkers(from: "修复跨域配置 [16]，完成验证[1][2]，保留【优先处理】。")
        try expect(cleaned == "修复跨域配置，完成验证，保留【优先处理】。", "每日总结没有移除数字来源标记")
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

    private static func verifyStructuredDailySummaryItems() throws {
        let summary = DailySummary(
            day: .now,
            content: """
            ## 今天的主线
            退款接口：定位重复退款校验缺失

            ## 真正完成的进展
            - 补充幂等测试：21 项测试通过

            ## 下一步
            - 提交修复 PR
            """,
            sourceCaptureIDs: [UUID()],
            todos: [],
            generationKind: .cloud
        )
        try expect(summary.items.count == 3, "模型总结没有迁移为可治理的结构化条目")
        try expect(summary.items.contains(where: { $0.section == .progress && $0.title.contains("补充幂等测试") }), "总结条目没有保留章节和具体事项")
        try expect(Set(summary.items.map(\.section)).isSubset(of: Set(DailySummarySection.displaySections)), "旧版七类总结没有迁移到三个用户维度")

        let longTitle = "回复李林关于 Android 测试机的机型与系统版本并确认华为设备上的整体裁剪问题是否已经完成复现"
        let untruncated = DailySummary(
            day: .now,
            content: "## 接下来要处理\n- \(longTitle)",
            sourceCaptureIDs: [],
            todos: [],
            generationKind: .cloud
        )
        try expect(untruncated.items.first?.title == longTitle, "无说明的长事项仍被程序按字符数截断")
        try expect(untruncated.items.first?.detail.isEmpty == true, "完整事项被重复写入详情")

        let legacyFullTitle = "设计文档《回调订单状态并发竞态修复.md》待补全（根因、修复 SQL、方案对比、锁与死锁分析、测试计划、上线验证步骤）"
        let repairedLegacy = DailySummary(
            day: .now,
            content: "## 近14天提醒与建议\n- \(legacyFullTitle)",
            sourceCaptureIDs: [],
            todos: [],
            generationKind: .cloud,
            items: [DailySummaryItem(
                section: .recent,
                title: String(legacyFullTitle.prefix(42)),
                detail: legacyFullTitle
            )]
        )
        try expect(repairedLegacy.items.first?.title == legacyFullTitle, "旧版 42 字截断条目没有在加载时恢复完整标题")
        try expect(repairedLegacy.items.first?.detail.isEmpty == true, "旧版标题前缀与完整详情仍被重复展示")

        let migratedEmptyItems = DailySummary(
            day: .now,
            content: "## 近14天提醒与建议\n- \(legacyFullTitle)",
            sourceCaptureIDs: [],
            todos: [],
            generationKind: .cloud,
            items: []
        )
        try expect(migratedEmptyItems.items.first?.title == legacyFullTitle, "已保存的空条目数组绕过了旧 Markdown 迁移")
        try expect(migratedEmptyItems.items.first?.section == .actions, "近 14 天旧栏目没有迁移到统一行动事项")

        let duplicatedLegacy = DailySummary(
            day: .now,
            content: """
            ## 尚未闭环
            - 补充退款幂等测试并提交 PR
            ## 待办与提醒
            - 【待办】补充退款幂等测试并提交 PR
            ## 下一步
            - 补充退款幂等测试并提交 PR
            """,
            sourceCaptureIDs: [],
            todos: [],
            generationKind: .cloud
        )
        try expect(duplicatedLegacy.items.count == 1 && duplicatedLegacy.items.first?.section == .actions, "旧版待办、未闭环和下一步没有归并去重")

        let structuredJSON = """
        {"headline":"**今天推进退款链路修复** [19][22]","progress":[{"title":"**补充幂等校验**","detail":"21 项测试通过 [23][24]"}],"actions":[{"title":"**提交退款修复 PR** [32]","detail":"等待评审"}],"insights":[{"title":"**跨证据比较**","detail":"客户端与服务端问题由同一组协作人并行推进 [33][34]","confidence":0.81,"evidenceIndices":[1,2]},{"title":"可能：单日流程可以长期复用","detail":"只跑通了两次","confidence":0.7},{"title":"低价值猜测","detail":"证据很弱","confidence":0.3}]}
        """
        let structuredItems = DailySummaryItemParser.itemsFromModelResponse(structuredJSON, defaultEvidenceIDs: [UUID(), UUID()]) ?? []
        try expect(structuredItems.filter { $0.section == .insights }.count == 1, "低置信度发现没有在后台过滤")
        try expect(!structuredItems.contains(where: { $0.title.contains("跨证据比较") || $0.title.contains("置信度") }), "算法术语仍暴露给普通用户")
        try expect(!structuredItems.contains(where: { $0.title.contains("**") || $0.detail.contains("**") }), "模型返回的 Markdown 加粗标记仍被当成普通文字展示")
        try expect(!structuredItems.contains(where: { $0.title.range(of: #"\[\d+\]"#, options: .regularExpression) != nil || $0.detail.range(of: #"\[\d+\]"#, options: .regularExpression) != nil }), "结构化模型条目仍展示引用编号")

        let uncertainInsight = DailySummary(
            day: .now,
            content: "## 值得留意\n- 可能：主线方法论与实际工作节奏高度同构：仅由当天一篇笔记推断",
            sourceCaptureIDs: [],
            todos: [],
            generationKind: .cloud
        )
        try expect(uncertainInsight.items.isEmpty, "低确定性的‘可能’判断仍进入值得留意")

        let noisy = DailySummary(
            day: .now,
            content: "## 下一步\n- c：定时任务扫描明细全终态但订单未完成的订单做补偿",
            sourceCaptureIDs: [],
            todos: [],
            generationKind: .cloud
        )
        try expect(noisy.items.first?.title == "定时任务扫描明细全终态但订单未完成的订单做补偿", "单字符 OCR 噪声仍被当作总结标题")
        try expect(noisy.items.first?.detail.isEmpty == true, "清理噪声标题后仍重复展示详情")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(DailySummary.self, from: encoder.encode(summary))
        try expect(restored.items == summary.items, "结构化总结条目没有持久化")
    }

    private static func verifyMemoryGovernanceDeletionAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let captureID = UUID()
        let screenshotPath = try storage.saveScreenshot(Data("image".utf8), captureID: captureID)
        let capture = CaptureRecord(
            id: captureID,
            eventTemplate: .manualMoment,
            sourceAppName: "Notes",
            sourceBundleIdentifier: "com.example.notes",
            imageRelativePath: screenshotPath,
            contentHash: "governance-hash",
            ocrText: "待办：明天提交退款幂等测试",
            summary: "明天提交退款幂等测试"
        )
        let summary = DailySummary(
            day: capture.createdAt,
            content: "## 待办与提醒\n- 提交退款幂等测试",
            sourceCaptureIDs: [capture.id],
            todos: [],
            generationKind: .localFallback
        )
        let linked = ReminderCandidate(title: "提交退款幂等测试", detail: "派生", sourceCaptureIDs: [capture.id], confidence: 0.9, origin: .discovered)
        let manual = ReminderCandidate(title: "手动提醒", detail: "保留", confidence: 1, origin: .manual)
        let answer = ConversationMessage(role: .assistant, content: "请提交退款幂等测试", citations: [capture.id])
        try await store.addCapture(capture)
        try await store.upsertDailySummary(summary)
        try await store.replaceReminders([linked, manual])
        try await store.addMessage(answer)
        try await store.updateConversationSummary("压缩摘要包含待办", coveredMessageCount: 1)

        guard let summaryItem = summary.items.first,
              let itemDeletion = try await store.removeDailySummaryItem(
                summaryID: summary.id,
                itemID: summaryItem.id,
                reason: .inaccurate
              ) else {
            throw VerificationError.failed("总结条目无法单独移除")
        }
        let afterItemDeletion = await store.snapshot()
        try expect(afterItemDeletion.dailySummaries.first?.content.contains("提交退款幂等测试") == false, "移除总结条目后旧 Markdown 仍进入检索")
        _ = try await store.restoreRecentlyDeleted(id: itemDeletion.id)

        let impact = await store.deletionImpact(for: [capture.id])
        try expect(impact.captureCount == 1 && impact.screenshotCount == 1 && impact.summaryCount == 1, "删除影响预览不准确")
        try expect(impact.reminderCount == 1 && impact.conversationCount == 1, "删除影响预览没有覆盖提醒或问一问")

        guard let deleted = try await store.moveCapturesToRecentlyDeleted(ids: [capture.id], reason: .inaccurate, suppressSimilar: false) else {
            throw VerificationError.failed("删除事务没有生成最近删除快照")
        }
        let afterDelete = await store.snapshot()
        try expect(afterDelete.captures.isEmpty && afterDelete.dailySummaries.isEmpty, "删除内容仍在在线记忆路径")
        try expect(afterDelete.reminders.map(\.id) == [manual.id], "删除来源误删手动提醒或残留派生提醒")
        try expect(afterDelete.messages.isEmpty && afterDelete.conversationSummary == nil, "删除来源后聊天回答或压缩上下文仍残留")
        try expect(!FileManager.default.fileExists(atPath: storage.screenshotURL(relativePath: screenshotPath).path), "删除截图没有移出在线目录")

        _ = try await store.restoreRecentlyDeleted(id: deleted.id)
        let restored = await store.snapshot()
        try expect(restored.captures.map(\.id) == [capture.id] && restored.dailySummaries.map(\.id) == [summary.id], "撤销没有恢复记录与总结")
        try expect(Set(restored.reminders.map(\.id)) == Set([linked.id, manual.id]), "撤销没有恢复派生提醒")
        try expect(restored.messages.map(\.id) == [answer.id] && restored.conversationSummary != nil, "撤销没有恢复聊天上下文")
        try expect(FileManager.default.fileExists(atPath: storage.screenshotURL(relativePath: screenshotPath).path), "撤销没有恢复截图")

        let expiredAt = Date.now.addingTimeInterval(-8 * 86_400)
        guard let expired = try await store.moveCapturesToRecentlyDeleted(ids: [capture.id], reason: .noLongerNeeded, suppressSimilar: false, now: expiredAt) else {
            throw VerificationError.failed("无法准备过期删除快照")
        }
        do {
            _ = try await store.restoreRecentlyDeleted(id: expired.id, now: expired.expiresAt)
            throw VerificationError.failed("到期的最近删除内容仍可恢复")
        } catch RecentlyDeletedRestoreError.expired {
            let unchanged = await store.snapshot()
            try expect(unchanged.captures.isEmpty && unchanged.recentlyDeletedMemories.count == 1, "拒绝到期恢复时修改了原始状态")
        }
        let purged = try await store.purgeExpiredRecentlyDeleted(now: .now)
        let afterPurge = await store.snapshot()
        try expect(purged == 1 && afterPurge.recentlyDeletedMemories.isEmpty, "过期的最近删除内容没有永久清理")
    }

    @MainActor
    private static func verifySuppressionLearning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        var capture = makeCapture(text: "忽略这段重复的测试记录内容", app: "mockeditor")
        capture.sourceBundleIdentifier = "com.example.mockeditor"
        try await store.addCapture(capture)
        _ = try await store.moveCapturesToRecentlyDeleted(ids: [capture.id], reason: .duplicate, suppressSimilar: true)
        let pipeline = CapturePipeline(store: store, storage: storage, screenCapturer: MockCapturer(), recognizer: MockRecognizer())
        let rule = EventRule(template: .manualMoment, isEnabled: true, scope: .textOnly)
        do {
            _ = try await pipeline.record(using: rule, userText: "忽略这段重复的测试记录内容")
            throw VerificationError.failed("已学习的忽略规则没有拦截相似采集")
        } catch CapturePipelineError.suppressedByUser {
            // 预期：只在本地拦截，不重新进入时间线、总结和提醒发现。
        }
    }

    private static func verifyReminderContextAndOwnership() throws {
        let base = Calendar.current.startOfDay(for: .now).addingTimeInterval(3_600)
        let extractor = ReminderExtractor()
        // 合成整段对话：角色必须跨句保留，不能把对方/助手的后半句变成用户的任务或偏好。
        let conversation = makeCapture(text: """
        [聊天·对方] 我可以说明配置方案。下一步：你同意后我把测试配置注入做掉；确认后我提交并推送到 stable。我喜欢每周修改配置。
        [聊天·角色未知] 待办：明天提交界面方案。
        [聊天·对方] 麻烦你明天回复客户验收邮件。
        [聊天·自己] 我更喜欢有结论的会议。
        """, app: "Chat", createdAt: base)
        let requests = extractor.candidates(from: [conversation], existing: [], now: base)
        try expect(requests.count == 1 && requests[0].title.contains("回复客户验收邮件"), "拆句后丢失角色或把助手承诺变成用户待办")
        try expect(requests[0].detail.hasPrefix("对方请求"), "对方明确请求没有保留归属")
        let memories = PersonalIntelligenceEngine().consolidate(day: base, records: [conversation]).memories
        try expect(memories.count == 1 && memories[0].content.contains("有结论的会议"), "对方第二句话仍污染长期偏好")
        let repeatedMemories = PersonalIntelligenceEngine().consolidate(day: base, records: [conversation], existingMemories: memories).memories
        try expect(repeatedMemories[0].confidence == memories[0].confidence, "重复运行使同一份证据的记忆评分不断上升")

        let noise = ["更新 abc1234..def5678", "支付设置「钱包」：关闭》开启", "修复（按验证方案", "确认后我提交并推送到 stable", "写一篇介绍语义检索的调研报告，需要包含实施方案"]
        for text in noise {
            let source = makeCapture(text: text, app: "Editor", createdAt: base)
            try expect(extractor.candidates(from: [source], existing: []).isEmpty, "未归属的屏幕文字变成待办：\(text)")
        }
        for text in noise.prefix(4) {
            try expect(!DailySummaryContentFormatter.isUsableAction(title: text), "旧总结质量门仍接收残句/助手建议/元数据：\(text)")
        }

        let finishedInMessage = makeCapture(text: "[聊天·自己] 待办：明天提交客户验收报价单。客户验收报价单已提交。", app: "Chat", createdAt: base)
        try expect(extractor.candidates(from: [finishedInMessage], existing: []).isEmpty, "同一条消息后半段已完成的事项又成为待办")
        let pending = makeCapture(text: "[聊天·自己] 待办：明天整理服务验收清单", app: "Chat", createdAt: base)
        let unrelated = makeCapture(text: "[聊天·自己] 已完成整理客户会议纪要", app: "Chat", createdAt: base.addingTimeInterval(60))
        let candidate = extractor.candidates(from: [pending, unrelated], existing: [], now: base)
        try expect(candidate.count == 1, "其他事项完成错误关闭了当前待办")
        let cancelled = makeCapture(text: "[聊天·自己] 整理服务验收清单的任务已取消", app: "Chat", createdAt: base.addingTimeInterval(120))
        try expect(extractor.candidates(from: [pending], existing: [], resolutionCaptures: [cancelled]).isEmpty, "后续取消证据没有参与旧候选校验")
        let otherCompleted = makeCapture(text: "[聊天·对方] 服务验收清单已完成", app: "Chat", createdAt: base.addingTimeInterval(120))
        try expect(extractor.candidates(from: [pending, otherCompleted], existing: []).count == 1, "他人完成事项被当作用户已完成")

        var manual = makeCapture(text: "每天上午九点检查账单同步结果", app: "Notes", createdAt: base)
        try expect(extractor.candidates(from: [manual], existing: []).isEmpty, "未标记来源被默认当作用户输入")
        manual.textOrigin = .userInput
        let recurrence = extractor.candidates(from: [manual], existing: [], now: base)
        try expect(recurrence.count == 1 && recurrence[0].recurrence == .daily, "用户明确输入的周期提醒被精度门误删")
        let practice = makeCapture(text: "提醒我每天上午十点练习口语", app: "Notes", createdAt: base)
        try expect(extractor.candidates(from: [practice], existing: []).first?.recurrence == .daily, "明确的周期练习提醒被漏掉")
        var scheduled = candidate[0]
        scheduled.id = UUID()
        scheduled.status = .scheduled
        var direct = candidate[0]
        direct.id = UUID()
        direct.origin = .manual
        let reconciled = extractor.merging([], into: [candidate[0], scheduled, direct], revalidatedCaptureIDs: [pending.id])
        try expect(Set(reconciled.map(\.id)) == Set([scheduled.id, direct.id]), "重验旧候选误删已安排或手动提醒")
        let kept = extractor.merging(candidate, into: [candidate[0]], revalidatedCaptureIDs: [pending.id])
        try expect(kept.first?.id == candidate[0].id, "重新分析有效候选丢失原标识")

        let legacyData = try JSONEncoder().encode(pending)
        let restored = try JSONDecoder().decode(CaptureRecord.self, from: legacyData)
        try expect(restored.textOrigin == nil, "旧采集记录被误迁移为用户输入")
        let oldCheckpoint = Data(#"{"processedCaptureHashes":{},"eligibleRecordCount":0,"analyzedRecordCount":0,"discoveredCount":0}"#.utf8)
        let restoredCheckpoint = try JSONDecoder().decode(ReminderDiscoveryCheckpoint.self, from: oldCheckpoint)
        try expect(restoredCheckpoint.extractorVersion == nil, "旧扫描检查点不能触发新提取器重验")
    }

    private static func verifySummaryModelReview() async throws {
        let day = Calendar.current.startOfDay(for: .now)
        let source = makeCapture(text: "[聊天·自己] 待办：明天提交客户报价方案，补齐成本说明后发给客户。", app: "Chat", createdAt: day.addingTimeInterval(3_600))
        let generator = DailySummaryGenerator()
        let empty = SummaryResponseStub { _ in #"{"headline":"","progress":[],"actions":[],"insights":[]}"# }
        let declined = try await generator.generate(day: day, from: [source], responder: empty)
        try expect(declined.generationKind == .cloud && declined.items.isEmpty && declined.todos.isEmpty, "模型明确返回空内容后仍被本地候选补回")
        try expect(!declined.content.contains("接下来要处理") && !declined.content.contains("值得留意"), "空栏目仍被展示")
        try expect(DailySummaryItemParser.itemsFromModelResponse("{}", defaultEvidenceIDs: []) == nil, "无协议字段的对象被当作有效总结")

        let rewrite = SummaryResponseStub { request in
            let range = request.question.range(of: #"(?<=candidateID=)[A-Fa-f0-9-]{36}"#, options: .regularExpression)
            let candidateID = range.map { String(request.question[$0]) } ?? UUID().uuidString
            return """
            {"progress":[],"actions":[{"candidateID":"\(candidateID)","title":"提交客户报价方案供评审","detail":"补齐成本说明后发给客户"}],"insights":[]}
            """
        }
        let rewritten = try await generator.generate(day: day, from: [source], responder: rewrite)
        try expect(rewritten.todos.count == 1 && rewritten.todos[0].title == "提交客户报价方案供评审", "模型核准的同一事项改写被规则原文覆盖")
        try expect(rewritten.todos[0].sourceCaptureIDs == [source.id] && rewritten.todos[0].dueAt != nil, "行动改写丢失准确来源或时间")
        try expect(rewritten.todos[0].priority == .normal, "识别分数被当作优先级")

        let invented = SummaryResponseStub { _ in #"{"progress":[],"actions":[{"candidateID":"00000000-0000-0000-0000-000000000000","title":"购买演示设备"}],"insights":[]}"# }
        let rejected = try await generator.generate(day: day, from: [source], responder: invented)
        try expect(rejected.todos.isEmpty, "不存在的候选 ID 被允许创造新待办")
        let corrupted = try await generator.generate(day: day, from: [source], responder: SummaryResponseStub { _ in "无法解析的响应" })
        try expect(corrupted.generationKind == .localFallback && corrupted.todos.count == 1, "无效模型响应未保留明确的本地提醒兜底")

        var closed = ReminderExtractor().candidates(from: [source], existing: [])[0]
        closed.status = .completed
        closed.completedAt = .now
        let resolved = try await generator.generate(day: day, from: [source], existingReminders: [closed])
        try expect(resolved.todos.isEmpty, "用户已完成的提醒又被每日总结复活")

        let pair = [makeCapture(text: "[聊天·自己] 测试环境的账单同步延迟连续两轮升高", app: "Notes", createdAt: day.addingTimeInterval(7_200)), makeCapture(text: "[聊天·自己] 账单同步延迟升高时重试队列也在增长", app: "Notes", createdAt: day.addingTimeInterval(10_800))]
        let groundedInsight = SummaryResponseStub { _ in #"{"progress":[],"actions":[],"insights":[{"title":"账单同步延迟与重试积压同时增长","detail":"两次检查分别记录延迟和积压，应继续观察其关联","confidence":0.9,"evidenceIndices":[1,2]}]}"# }
        let supported = try await generator.generate(day: day, from: pair, responder: groundedInsight)
        try expect(supported.items.filter { $0.section == .insights }.count == 1, "有两条独立来源的发现没有保留")
        let single = try await generator.generate(day: day, from: [pair[0]], responder: groundedInsight)
        try expect(single.items.filter { $0.section == .insights }.isEmpty, "不存在的来源编号仍支撑发现")
        var duplicate = pair[0]
        duplicate.id = UUID()
        duplicate.createdAt = pair[1].createdAt
        let repeated = try await generator.generate(day: day, from: [pair[0], duplicate], responder: groundedInsight)
        try expect(repeated.items.filter { $0.section == .insights }.isEmpty, "同一内容重复截图被当成两条独立证据")
        let markdown = SummaryResponseStub { _ in "## 值得留意\n- 账单同步延迟与重试积压同时增长：应继续观察其关联" }
        let ungrounded = try await generator.generate(day: day, from: pair, responder: markdown)
        try expect(ungrounded.items.filter { $0.section == .insights }.isEmpty, "Markdown 回退用整份请求的来源冒充逐项证据")
    }

    private static func verifyDailySummaryActionPrecision() async throws {
        let normalized = DailySummaryContentFormatter.normalizingNextActionSection(
            in: "## 今天的主线\n修复每日回顾。\n\n## 近14天提醒与建议\n- 页面以系统流程为中心，属于长期产品改进方向。\n\n## 下一步\n\n- 今天",
            fallbackActions: ["补充每日回顾滚动测试并提交 PR"]
        )
        try expect(!normalized.contains("- 今天"), "无意义的单独时间词仍被保留为下一步")
        try expect(!normalized.contains("以系统流程为中心"), "已保存总结中的抽象业务方向没有在展示时清理")
        try expect(normalized.contains("补充每日回顾滚动测试并提交 PR"), "模型下一步无效时没有使用本地结构化动作兜底")

        let withoutAction = DailySummaryContentFormatter.normalizingNextActionSection(
            in: "## 今天的主线\n修复每日回顾。\n\n## 下一步\n\n- 继续"
        )
        try expect(!withoutAction.contains("## 接下来要处理"), "没有具体动作时仍展示空洞的行动小节")

        let badActions = DailySummaryItemParser.sanitized([
            DailySummaryItem(section: .actions, title: "不要问“今天我要完成多少事”", detail: "而要问“我长期到底在构建什么”"),
            DailySummaryItem(section: .actions, title: "下一步是修复", detail: "下一步是修复"),
            DailySummaryItem(section: .actions, title: "生产环境需要登录才能验证，问下你想怎么处理："),
            DailySummaryItem(section: .actions, title: "的一条底层原则：Leader 的目标不是完成任务"),
            DailySummaryItem(section: .actions, title: "网络异常，请检查网络后再试"),
            DailySummaryItem(section: .actions, title: "解释为什么人坐下来却干不了活：脑子同时挂着过去的懊悔、未来的任务、未完成事项"),
            DailySummaryItem(section: .actions, title: "发布日期：2026年9月18日", detail: "发布日期：2026年9月18日；截止：2026年9月18日 9:00"),
            DailySummaryItem(section: .actions, title: "完成 4 篇纯中文完整译文", detail: "完成 4 篇纯中文完整译文"),
            DailySummaryItem(section: .actions, title: "提交记录：0a92cfcn", detail: "提交记录：0a92cfcn"),
            DailySummaryItem(section: .actions, title: "24 小时过期，用户每天最多登录一次", detail: "期限事项 · Orca；截止：2026年10月13日 9:00"),
            DailySummaryItem(section: .actions, title: "30 分钟无操作即过期", detail: "期限事项 · Orca"),
            DailySummaryItem(section: .actions, title: "准备工作是最重要的部分", detail: "知识笔记"),
            DailySummaryItem(section: .actions, title: "[聊天·对方] 用户 PC 网页提交订单—请求后端【创建支付单】"),
            DailySummaryItem(section: .actions, title: "若业务确认要维持每天登录一次的体验，就按 24h 配置")
        ])
        try expect(badActions.isEmpty, "文章观点、助手追问或无对象残句仍被归入接下来要处理")
        try expect(DailySummaryItemParser.markdown(from: badActions).isEmpty, "没有明确行动时仍展示接下来要处理模块")

        let validActions = DailySummaryItemParser.sanitized([
            DailySummaryItem(
                section: .actions,
                title: "明天补充退款幂等测试并提交 PR",
                detail: "待办；截止：2026年9月23日 18:00"
            )
        ])
        try expect(validActions.count == 1, "收紧完成态过滤时误删了明确未完成的具体行动")

        let brokenInsights = DailySummaryItemParser.sanitized([
            DailySummaryItem(section: .insights, title: "的、需要我协调的和后续责任分别定下来 已连续多日没有新进展", detail: "该项目仍保留下一步；若继续，下一步是：×|图 提取内容比较"),
            DailySummaryItem(section: .insights, title: "近期多次出现上下文切换偏多", detail: "记录涉及 33 条工作主线并形成 59 个工作片段"),
            DailySummaryItem(section: .insights, title: "生产超时与儿童 PNR 很可能是同一条 IBE 链路问题", detail: "同一天出现超时和 PNR 错误"),
            DailySummaryItem(section: .insights, title: "航旅接口错误率连续三天升高", detail: "生产监控显示错误率逐日增加")
        ])
        try expect(brokenInsights.map(\.title) == ["航旅接口错误率连续三天升高"], "旧洞察里的 OCR 断句或截图计数推断仍在展示")

        let noisyPrefix = DailySummaryContentFormatter.normalizingNextActionSection(
            in: "## 今天的主线\n修复订单状态。\n\n## 下一步\n\n- c：定时任务扫描明细全终态但订单未完成的订单做补偿"
        )
        try expect(!noisyPrefix.contains("- c："), "单字符噪声仍出现在下一步标题中")
        try expect(noisyPrefix.contains("定时任务扫描明细全终态但订单未完成的订单做补偿"), "清理噪声时误删了具体下一步")

        let calendar = Calendar.current
        let day = calendar.startOfDay(for: .now)
        let source = makeCapture(text: "今天完成 Recall 每日回顾标题滚动修复。", app: "Xcode", createdAt: day.addingTimeInterval(10 * 60 * 60))
        let previous = DailySummary(
            day: calendar.date(byAdding: .day, value: -1, to: day)!,
            content: "历史摘要",
            sourceCaptureIDs: [],
            todos: [
                DailySummaryTodo(
                    title: "页面以系统流程为中心，而不是以用户为中心，属于长期产品改进方向",
                    detail: "长期业务描述",
                    priority: .normal
                ),
                DailySummaryTodo(
                    title: "补充退款幂等测试并提交 PR",
                    detail: "明确可执行动作",
                    priority: .high
                )
            ],
            generationKind: .localFallback
        )
        let generated = try await DailySummaryGenerator().generate(
            day: day,
            from: [source],
            previousSummaries: [previous],
            responder: nil,
            calendar: calendar
        )
        try expect(!generated.content.contains("以系统流程为中心"), "长期产品方向仍被误报为当前跟进行动")
        try expect(!generated.content.contains("补充退款幂等测试并提交 PR"), "已保存总结快照中的历史动作仍被复制到当天总结")
    }

    private static func verifyPersonalIntelligenceConsolidation() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 9))!
        var first = makeCapture(text: "项目：Recall 正在重构每日简报。", app: "Xcode", createdAt: day)
        first.windowTitle = "Recall - Xcode"
        var second = makeCapture(text: "项目：Recall 已完成 Episode 聚类，测试通过。下一步：接入反馈。", app: "Xcode", createdAt: day.addingTimeInterval(20 * 60))
        second.windowTitle = "Recall - Xcode"
        var preference = makeCapture(text: "[聊天·自己] 我喜欢高密度、少打扰的个人建议。", app: "Notes", createdAt: day.addingTimeInterval(90 * 60))
        preference.windowTitle = "个人工作约定 - Notes"

        let engine = PersonalIntelligenceEngine()
        let result = engine.consolidate(day: day, records: [first, second, preference], calendar: calendar)
        try expect(result.episodes.count == 2, "相邻的同项目记录没有合并为工作片段")
        try expect(result.episodes.first(where: { $0.projectName == "Recall" })?.status == .completed, "工作片段没有识别已完成结果")
        try expect(result.projectStates.contains(where: { $0.projectKey.contains("recall") }), "工作片段没有更新项目状态")
        try expect(result.memories.contains(where: { $0.kind == .preference && $0.status == .confirmed }), "明确偏好没有在后台自动沉淀为长期记忆")
        try expect(result.briefing.memoryCandidates.isEmpty, "长期用户认识仍然混入每日总结要求确认")
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
        var menuNoise = makeCapture(
            text: "今天推进：职业助手 docker java 200keeper 好文章 设计模式 学习成长 源码学习 课外知识 >产品设计 通讯录 微盘 更多 Q 搜索。",
            app: "企业微信",
            createdAt: day.addingTimeInterval(160 * 60)
        )
        menuNoise.windowTitle = "职业助手 docker java 200keeper 好文章 设计模式 学习成长 源码学习 课外知识 >产品设计"
        let processNoise = makeCapture(text: "已完成并合并到main。最终提交：34cdc34n。", app: "Terminal", createdAt: day.addingTimeInterval(180 * 60))
        let ocrNoise = makeCapture(text: "完成 ×|C) col x|S 集况×。", app: "Terminal", createdAt: day.addingTimeInterval(200 * 60))

        let result = PersonalIntelligenceEngine().consolidate(day: day, records: [first, second, noise, menuNoise, processNoise, ocrNoise])
        let conclusionText = ([result.briefing.headline] +
            result.briefing.progress.map(\.title) +
            result.briefing.openLoops.map(\.title) +
            result.insights.map(\.title)).joined(separator: "\n")
        try expect(conclusionText.contains("退款订单接口修复"), "每日简报没有提取到具体事项")
        try expect(!conclusionText.contains("企业微信") && !conclusionText.contains("localmcp"), "应用或工具名仍被当成总结事项")
        try expect(!conclusionText.contains("200keeper") && !conclusionText.contains("34cdc34") && !conclusionText.contains("col x|S"), "菜单、哈希或 OCR 乱码仍进入总结")
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
        try expect(initial.insights.first(where: { $0.kind == .contextSwitching })?.confidence ?? 1 < 0.75, "单日上下文切换被直接作为高价值发现展示")
        let repeatedDay = day.addingTimeInterval(86_400)
        let repeatedRecords = (0..<4).map { index in
            makeCapture(
                text: "项目：Repeated\(index) 正在处理不同任务。",
                app: "Editor",
                createdAt: repeatedDay.addingTimeInterval(Double(index) * 70 * 60)
            )
        }
        let repeated = engine.consolidate(day: repeatedDay, records: repeatedRecords, previousInsights: initial.insights)
        try expect(repeated.insights.first(where: { $0.kind == .contextSwitching })?.confidence ?? 1 < 0.75, "截图计数被升级为真实上下文切换判断")
        let fragmentProject = ProjectState(
            projectKey: "topic:fragment",
            displayName: "的、需要我协调的和后续责任分别定下来",
            currentState: "OCR 半句",
            nextAction: "确认具体责任人",
            confidence: 0.8,
            lastActiveAt: day.addingTimeInterval(-4 * 86_400)
        )
        let ordinaryProject = ProjectState(projectKey: "topic:export", displayName: "账单导出", currentState: "等待测试", nextAction: "补充账单导出测试", confidence: 0.9, lastActiveAt: day.addingTimeInterval(-10 * 86_400))
        let broken = engine.consolidate(day: day, records: records, previousProjects: [fragmentProject, ordinaryProject])
        try expect(!broken.insights.contains(where: { $0.kind == .stalledWork }), "历史 OCR 半句仍被拼成停滞项目洞察")
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
        let capture = makeCapture(text: "项目：RecallUniqueFTSTerm 完成智能索引迁移", app: "Verifier")
        try await store.addCapture(capture)
        let indexed = await store.indexedCaptureIDs(matching: "RecallUniqueFTSTerm")
        try expect(indexed == [capture.id], "FTS5 没有检索到已持久化的记录")

        let insightRecords = [capture] + (1...3).map { index in
            makeCapture(
                text: "项目：Persistence\(index) 推进独立验证事项",
                app: "Verifier",
                createdAt: capture.createdAt.addingTimeInterval(Double(index) * 70 * 60)
            )
        }
        for record in insightRecords.dropFirst() { try await store.addCapture(record) }
        let consolidation = PersonalIntelligenceEngine().consolidate(day: capture.createdAt, records: insightRecords)
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
        try expect(capture.ocrText == PrivacyEngine().redact("请联系 alice@example.com，密码: demo-secret"), "摘要生成截断或改写了完整 OCR")
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

    private static func verifyTypewriterSequence() throws {
        let content = "第一段回答。\n\n第二段回答。"
        let chunks = TypewriterTextSequence.chunks(for: content, maximumSteps: 5)
        try expect(chunks.count <= 5, "打字机片段超过设定的最大呈现步数")
        try expect(chunks.joined() == content, "打字机分片没有无损还原模型回答")
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

    @MainActor
    private static func verifySevenDayOverviewCoverage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var summaryIDs: [UUID] = []

        for offset in 0..<7 {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let summary = DailySummary(
                day: day,
                content: "第 \(offset + 1) 天完成事项：推进项目阶段 \(offset + 1)。",
                sourceCaptureIDs: [],
                todos: [],
                generationKind: .localFallback
            )
            summaryIDs.append(summary.id)
            try await store.upsertDailySummary(summary)
        }
        // 模拟今天记录很多的真实场景，验证它们不会挤掉前六天。
        for index in 0..<10 {
            try await store.addCapture(makeCapture(text: "今天的高频工作记录 \(index)", app: "Xcode", createdAt: .now.addingTimeInterval(Double(-index))))
        }
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .localOnly))

        let answer = try await MemoryAssistant(store: store).ask("我最近七天做了哪些事情？")
        try expect(Set(summaryIDs).isSubset(of: Set(answer.citations)), "七天概览被今天的高频记录占满，没有覆盖每天的总结")
        try expect(answer.content.contains("第 7 天完成事项"), "七天概览没有包含时间范围最早一天的内容")
    }

    @MainActor
    private static func verifyDailySummaryQuestionRetrieval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let summary = DailySummary(
            day: .now,
            content: "家庭事项：妙妙的 6 岁生日聚会已办，安安、糯米和小满到场；现有记录没有写妙妙的出生日期。",
            sourceCaptureIDs: [],
            todos: [],
            generationKind: .localFallback
        )
        try await store.upsertDailySummary(summary)
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .localOnly))

        let assistant = MemoryAssistant(store: store)
        let first = try await assistant.ask("妙妙什么时候过生日？")
        try expect(first.citations == [summary.id], "问一问没有把每日总结作为可追溯证据")
        try expect(first.content.contains("妙妙的 6 岁生日聚会已办"), "问一问没有召回每日总结中的家庭事项")

        let followUp = try await assistant.ask("你看下之前内容")
        try expect(followUp.citations == [summary.id], "连续追问没有沿用上一轮检索主题")
        try expect(followUp.content.contains("妙妙"), "连续追问丢失了上一轮人物语境")
    }

    @MainActor
    private static func verifyChatCommands() async throws {
        try expect(ChatCommand.suggestions(for: "/") == [.clear], "输入斜杠应提示可用命令")
        try expect(ChatCommand.suggestions(for: "/cl") == [.clear], "命令列表应按前缀筛选")
        try expect(ChatCommand.suggestions(for: "正文 /clear").isEmpty && ChatCommand.suggestions(for: "/clear\n正文").isEmpty, "正文与多行输入不应误开命令菜单")
        try expect(ChatCommand.parse("  /clear  ") == .clear && ChatCommand.parse("/clear more") == nil, "清空必须匹配完整命令，不能接受参数")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Recall-Commands-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        let capture = makeCapture(text: "测试记忆：项目预算周五评审", app: "测试笔记")
        try await store.addCapture(capture)
        let reminder = ReminderCandidate(title: "提交预算评审", detail: "测试提醒", dueAt: .now, sourceCaptureIDs: [capture.id], confidence: 0.9)
        try await store.updateReminder(reminder)
        let summary = DailySummary(day: .now, content: "## 今天推进了什么\n- 整理预算评审资料", sourceCaptureIDs: [capture.id], todos: [], generationKind: .localFallback)
        try await store.upsertDailySummary(summary)
        try await store.addMessage(ConversationMessage(role: .user, content: "旧会话问题"))
        try await store.addMessage(ConversationMessage(role: .assistant, content: "旧会话回答"))
        try await store.updateConversationSummary("不能留在新会话中的旧摘要", coveredMessageCount: 2)
        try await store.updatePrivacy(PrivacySettings(cloudUseEnabled: true))
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .openAICompatible, apiKey: ""))
        let assistant = MemoryAssistant(store: store)
        let result = try await assistant.ask("/clear")
        let cleared = await store.snapshot()
        try expect(result.role == .system && result.content.contains("已清空"), "命令应本地返回实际执行结果，无模型密钥也能工作")
        try expect(cleared.messages.map(\.id) == [result.id] && cleared.conversationSummary == nil && cleared.conversationSummaryCoveredMessageCount == 0, "清空应移除全部聊天历史及压缩上下文，只留下命令结果")
        try expect(cleared.captures.map(\.id) == [capture.id] && cleared.reminders.map(\.id) == [reminder.id] && cleared.dailySummaries.map(\.id) == [summary.id], "清会话不能删除采集、提醒和每日总结")
        let reloaded = try FileMemoryStore(storage: storage)
        let persisted = await reloaded.snapshot()
        try expect(persisted.messages.map(\.id) == [result.id] && persisted.conversationSummary == nil, "重启后不能恢复已清空的会话和摘要")
        let unknown = try await assistant.ask("/unknown")
        try expect(unknown.role == .system && unknown.content.contains("未识别"), "未知命令不能发送大模型或伪报成功")
        let beforeInvalid = await store.conversationSnapshot()
        let invalid = try await assistant.ask("/clear extra")
        let afterInvalid = await store.conversationSnapshot()
        try expect(invalid.role == .system && afterInvalid.id == beforeInvalid.id && afterInvalid.state.messages.contains(where: { $0.id == result.id }), "错误参数不能清空当前会话")
        _ = try await assistant.ask("/clear")
        try await store.addMessage(ConversationMessage(role: .user, content: "保存失败时应保留的消息"))
        try await store.updateConversationSummary("保存失败时应保留的上下文", coveredMessageCount: 1)
        let beforeFailure = await store.conversationSnapshot()
        let backup = root.appendingPathComponent("state-backup.json")
        do {
            try FileManager.default.moveItem(at: storage.stateURL, to: backup)
            defer {
                try? FileManager.default.removeItem(at: storage.stateURL)
                try? FileManager.default.moveItem(at: backup, to: storage.stateURL)
            }
            try FileManager.default.createDirectory(at: storage.stateURL, withIntermediateDirectories: false)
            var didFail = false
            do { _ = try await store.clearConversation() } catch { didFail = true }
            let failed = await store.conversationSnapshot()
            try expect(didFail && failed.id == beforeFailure.id && failed.state.messages == beforeFailure.state.messages && failed.state.conversationSummary == beforeFailure.state.conversationSummary, "落盘失败应恢复原会话和身份，不得返回清空成功")
        }
    }

    @MainActor
    private static func verifyConversationClearRace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Recall-Clear-Race-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        try await store.addCapture(makeCapture(text: "测试项目：上周完成预算方案", app: "测试笔记"))
        let old = await store.conversationSnapshot()
        let assistant = MemoryAssistant(store: store)
        do {
            _ = try await assistant.ask("上次做了什么？", onUserMessageSaved: {
                // Deterministically clear while an earlier request is suspended after saving.
                _ = try? await store.clearConversation()
            })
            throw VerificationError.failed("旧会话回答不应写回已清空的会话")
        } catch is CancellationError {}
        let fresh = await store.snapshot()
        try expect(fresh.messages.count == 1 && fresh.messages.first?.role == .system, "清空期间的旧请求不能重新填入问答")
        do {
            try await store.updateConversationSummary("延迟返回的旧摘要", coveredMessageCount: 1, inConversation: old.id)
            throw VerificationError.failed("旧摘要不应写入新会话")
        } catch is CancellationError {}
        do {
            try await store.addMessage(ConversationMessage(role: .assistant, content: "延迟返回的旧回答"), inConversation: old.id)
            throw VerificationError.failed("旧回答不应写入新会话")
        } catch is CancellationError {}
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .localOnly))
        let answer = try await assistant.ask("之前内容是什么？")
        let after = await store.snapshot()
        try expect(answer.role == .assistant && after.messages.count == 3 && after.conversationSummary == nil, "清空后新问题应正常开始，不带回旧上下文")
    }

    @MainActor
    private static func verifyQuestionPersistsBeforeModelFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecallStorage(rootURL: root)
        let store = try FileMemoryStore(storage: storage)
        try await store.updatePrivacy(PrivacySettings(cloudUseEnabled: true))
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .openAICompatible, apiKey: ""))
        let probe = ChatPersistenceProbe()

        do {
            _ = try await MemoryAssistant(store: store).ask("这条消息应立即显示") {
                probe.didRefreshAfterSave = true
            }
            throw VerificationError.failed("缺少 API Key 时问一问应失败")
        } catch LLMError.missingAPIKey {
            // 预期：模型请求失败，但用户消息已经持久化并触发界面刷新。
        }
        let snapshot = await store.snapshot()
        try expect(probe.didRefreshAfterSave, "用户消息保存后没有立即通知界面刷新")
        try expect(snapshot.messages.count == 1 && snapshot.messages[0].role == .user, "模型失败前用户消息没有先写入本地会话")
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

@MainActor
private final class ChatPersistenceProbe {
    var didRefreshAfterSave = false
}

private struct SummaryResponseStub: LLMResponding {
    let content: @Sendable (LLMRequest) -> String
    init(_ content: @escaping @Sendable (LLMRequest) -> String) { self.content = content }
    func answer(to request: LLMRequest) async throws -> LLMAnswer {
        LLMAnswer(content: content(request), citedCaptureIDs: request.context.map(\.id))
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
