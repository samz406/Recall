import Foundation
import RecallKit

/// Fabricated evidence only; exercises the persisted feedback -> revision -> future context contract.
enum SummaryFeedbackVerification {
    private struct Failure: LocalizedError { let text: String; var errorDescription: String? { text } }
    private static func check(_ value: @autoclosure () -> Bool, _ text: String) throws { if !value() { throw Failure(text: text) } }
    private struct Fixture {
        let store: FileMemoryStore
        let storage: RecallStorage
        let source: CaptureRecord
        let other: CaptureRecord
        let summary: DailySummary
        let config = LLMConfiguration(provider: .openAICompatible, apiKey: "verification-placeholder")
        let privacy = PrivacySettings(cloudUseEnabled: true)
    }
    private struct Responder: LLMResponding {
        let response: String
        var audit = true
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            if request.purpose == .summaryFeedbackAudit {
                return LLMAnswer(content: "{\"addressesFeedback\":\(audit),\"supported\":true,\"preservesOthers\":true,\"correctAttribution\":true,\"preservesTime\":true,\"rulesExplicit\":true}", citedCaptureIDs: [])
            }
            return LLMAnswer(content: response, citedCaptureIDs: [])
        }
    }
    private static func fixture() async throws -> Fixture {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-feedback-" + UUID().uuidString))
        let store = try FileMemoryStore(storage: storage)
        let source = CaptureRecord(eventTemplate: .workCheckpoint, sourceAppName: "测试聊天", sourceBundleIdentifier: "example.chat",
            contentHash: "feedback-fixture-a", ocrText: "[聊天·自己] Atlas 导出修复已完成上线。\n[聊天·对方] 明天核对分页边界。")
        let other = CaptureRecord(eventTemplate: .workCheckpoint, sourceAppName: "测试笔记", sourceBundleIdentifier: "example.notes",
            contentHash: "feedback-fixture-b", ocrText: "[聊天·自己] Atlas 发票下载通过空值测试。")
        let items = [DailySummaryItem(section: .progress, title: "Atlas 导出修复已上线", detail: "导出修复完成。", evidenceIDs: [source.id]),
                     DailySummaryItem(section: .progress, title: "发票下载通过空值测试", evidenceIDs: [other.id])]
        let summary = DailySummary(day: .now, content: DailySummaryItemParser.markdown(from: items), sourceCaptureIDs: [source.id, other.id], todos: [], generationKind: .cloud, items: items)
        let result = Fixture(store: store, storage: storage, source: source, other: other, summary: summary)
        try await store.addCapture(source); try await store.addCapture(other)
        try await store.updatePrivacy(result.privacy); try await store.updateLLMConfiguration(result.config)
        try await store.upsertDailySummary(summary)
        return result
    }
    private static func response(_ f: Fixture, diagnosis: String = "expression", title: String = "Atlas 导出修复完成", corrections: [[String: Any]] = [], rules: [[String: Any]] = [], remove: Bool = false) throws -> String {
        let change: [String: Any] = ["itemID": f.summary.items[0].id.uuidString, "remove": remove, "title": title,
                                    "detail": "目前只完成联调，尚未上线。", "section": "progress", "sourceIDs": [f.source.id.uuidString]]
        let json: [String: Any] = ["diagnosis": diagnosis, "message": "已核对并调整导出修复的表述。", "changes": [change], "corrections": corrections, "rules": rules]
        return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }
    private static func submit(_ f: Fixture, text: String) async throws -> SummaryFeedback {
        _ = try await f.store.submitSummaryFeedback(target: .daily(f.summary, item: f.summary.items[0]), text: text)
        guard let job = try await f.store.claimSummaryFeedback(modelAvailable: true) else { throw Failure(text: "未领取反馈任务") }
        return job
    }
    private static func apply(_ f: Fixture, job: SummaryFeedback, response: String) async throws {
        let state = await f.store.snapshot()
        let plan = try await SummaryFeedbackEngine().resolve(job, in: state, responder: Responder(response: response))
        try await f.store.finishSummaryFeedback(job, plan: plan, configuration: f.config, privacy: f.privacy)
    }
    static func run() async throws {
        try await persistenceAndRecovery()
        try await repairAndUndo()
        try await exactCorrection()
        try await scopedRules()
        try await rejectionAndRaces()
        try await deletionAndPause()
        try await periodRepair()
        try await supplementAndUndo()
        print("PASS: feedback covers durable queue, bounded patches, exact facts, scoped learning, audit rejection, concurrency, pause, deletion and undo")
    }
    private static func persistenceAndRecovery() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let first = try await f.store.submitSummaryFeedback(target: .daily(f.summary), text: "结果应当放在前面。")
        let duplicate = try await f.store.submitSummaryFeedback(target: .daily(f.summary), text: "结果应当放在前面。")
        try check(first.id == duplicate.id, "重复提交生成了两个任务")
        _ = try await f.store.claimSummaryFeedback(modelAvailable: true)
        let reopened = try FileMemoryStore(storage: f.storage)
        try await reopened.recoverSummaryFeedbackJobs()
        let snapshot = await reopened.snapshot()
        try check(snapshot.summaryFeedback.count == 1 && snapshot.summaryFeedback[0].state == .queued && snapshot.summaryFeedback[0].lease == nil, "重启丢失任务或保留死锁租约")
        let data = try JSONEncoder().encode(RecallState())
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "summaryFeedback"); json.removeValue(forKey: "summaryFeedbackSettings")
        let legacy = try JSONDecoder().decode(RecallState.self, from: JSONSerialization.data(withJSONObject: json))
        try check(legacy.summaryFeedback.isEmpty && legacy.summaryFeedbackSettings.processingEnabled, "旧状态不能安全迁移")
    }
    private static func repairAndUndo() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let job = try await submit(f, text: "这条请改成联调完成，暂未上线。")
        try await apply(f, job: job, response: response(f))
        let after = await f.store.snapshot()
        let revised = after.dailySummaries.first { $0.id == f.summary.id }
        try check(revised?.items[0].title == "Atlas 导出修复完成" && revised?.items.contains(f.summary.items[1]) == true, "局部修订误改其他事项")
        try check(revised?.versions?.first?.items == f.summary.items && after.captures.contains(f.source), "修订没有保留原版本或篡改原始采集")
        try await f.store.withdrawSummaryFeedback(job.id)
        let restored = await f.store.snapshot()
        try check(restored.dailySummaries.first?.items == f.summary.items && restored.summaryFeedback[0].state == .withdrawn, "撤销未恢复原内容")
    }
    private static func exactCorrection() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let job = try await submit(f, text: "原记录第一句识别错了，我说的是只完成联调，尚未上线。")
        let corrections: [[String: Any]] = [["sourceID": f.source.id.uuidString, "originalQuote": "[聊天·自己] Atlas 导出修复已完成上线。", "correctedQuote": "[聊天·自己] Atlas 导出修复只完成联调，尚未上线。"]]
        try await apply(f, job: job, response: response(f, diagnosis: "facts", corrections: corrections))
        let state = await f.store.snapshot()
        let adjusted = state.correctedForAnalysis().captures.first { $0.id == f.source.id }
        try check(state.captures.contains(f.source) && adjusted?.ocrText.contains("只完成联调，尚未上线") == true && adjusted?.ocrText.contains("[聊天·对方] 明天核对分页边界。") == true, "片段纠错改了原图文字或吞掉邻近消息")
        try check(SummaryFeedbackLearning.correctionID(for: f.source.id, quote: "Atlas 导出修复只完成联调，尚未上线。", in: state) == job.id, "用户更正缺少独立来源标识")
        let reloaded = try FileMemoryStore(storage: f.storage)
        let reloadedState = await reloaded.snapshot()
        try check(reloadedState.correctedForAnalysis().captures.first { $0.id == f.source.id }?.ocrText == adjusted?.ocrText, "重启丢失事实纠错")
    }
    private static func scopedRules() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let job = try await submit(f, text: "以后每日回顾先写结果。")
        let rules: [[String: Any]] = [["kind": "outcomesFirst", "quote": "以后每日回顾先写结果", "allReviews": true]]
        try await apply(f, job: job, response: response(f, rules: rules))
        let state = await f.store.snapshot()
        try check(SummaryFeedbackLearning.context(in: state, kind: .daily).contains("先写具体结果"), "后续每日回顾没有读取偏好")
        try check(SummaryFeedbackLearning.context(in: state, kind: .period, templateID: "work").isEmpty, "单个回顾偏好泄漏至工作周报")
        let ruleID = state.summaryFeedback[0].resolution!.rules[0].id
        try await f.store.disableSummaryRule(feedbackID: job.id, ruleID: ruleID)
        let disabled = await f.store.snapshot()
        try check(SummaryFeedbackLearning.rules(in: disabled, kind: .daily).isEmpty, "停用后仍在应用规则")
    }
    private static func rejectionAndRaces() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let job = try await submit(f, text: "请改成联调完成。")
        let state = await f.store.snapshot()
        do {
            _ = try await SummaryFeedbackEngine().resolve(job, in: state, responder: Responder(response: response(f), audit: false))
            throw Failure(text: "错误接受独立核验否决的修订")
        } catch is SummaryFeedbackError {}
        do {
            let rules: [[String: Any]] = [["kind": "concise", "quote": "请改成联调完成", "allReviews": false]]
            _ = try await SummaryFeedbackEngine().resolve(job, in: state, responder: Responder(response: response(f, rules: rules)))
            throw Failure(text: "一次反馈自动升级为永久偏好")
        } catch is SummaryFeedbackError {}
        let plan = try await SummaryFeedbackEngine().resolve(job, in: state, responder: Responder(response: response(f)))
        var changed = f.summary; changed.items[0].title = "用户已经手动修改标题"
        try await f.store.upsertDailySummary(changed)
        do {
            try await f.store.finishSummaryFeedback(job, plan: plan, configuration: f.config, privacy: f.privacy)
            throw Failure(text: "过期反馈覆盖了新版本")
        } catch is SummaryFeedbackError {}
    }
    private static func deletionAndPause() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let job = try await submit(f, text: "请修改这句的结果。")
        var settings = SummaryFeedbackSettings(); settings.processingEnabled = false
        try await f.store.updateSummaryFeedbackSettings(settings)
        do { try await f.store.validateSummaryFeedbackJob(job, configuration: f.config, privacy: f.privacy); throw Failure(text: "暂停后仍允许模型请求") }
        catch is SummaryFeedbackError {}
        _ = try await f.store.moveCapturesToRecentlyDeleted(ids: [f.source.id], reason: .noLongerNeeded, suppressSimilar: false)
        let state = await f.store.snapshot()
        try check(state.summaryFeedback.isEmpty, "删除来源后残留反馈文字、快照或规则")
    }
    private static func supplementAndUndo() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let text = "漏了一件事，我今天完成了 Atlas 订单接口的分页修复。"
        _ = try await f.store.submitSummaryFeedback(target: .daily(f.summary), text: text)
        guard let job = try await f.store.claimSummaryFeedback(modelAvailable: true) else { throw Failure(text: "未领取补记反馈") }
        let formatter = DateFormatter(); formatter.calendar = job.target.period.calendar
        formatter.timeZone = formatter.calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let json: [String: Any] = ["diagnosis": "omission", "message": "已保存用户补记并补入回顾。", "corrections": [], "rules": [],
            "supplement": ["title": "Atlas 订单接口分页修复", "detail": "Atlas 订单接口的分页问题已经完成修复。", "status": "completed", "quote": "我今天完成了 Atlas 订单接口的分页修复", "occurredOn": formatter.string(from: job.createdAt)],
            "changes": [["itemID": NSNull(), "remove": false, "title": "Atlas 订单接口分页修复完成", "detail": "用户补充：订单接口的分页问题已完成修复。", "section": "progress", "sourceIDs": [job.id.uuidString]]]]
        try await apply(f, job: job, response: String(decoding: JSONSerialization.data(withJSONObject: json), as: UTF8.self))
        let state = await f.store.snapshot()
        try check(state.captures.first { $0.id == job.id }?.sourceAppName == "用户反馈补记" && state.dailySummaries.first?.items.count == 3,
                  "明确补充没有保存为独立用户来源或没有加入总结")
        try await f.store.withdrawSummaryFeedback(job.id)
        let undone = await f.store.snapshot()
        try check(!undone.captures.contains { $0.id == job.id } && undone.dailySummaries.first?.items == f.summary.items,
                  "撤销补记留下了虚构的截图来源或没有恢复回顾")
    }
    private static func periodRepair() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let source = try ManualMatterNote(title: "Atlas 发布流程改版", detail: "发布流程的步骤导航已通过验收。", status: .completed, eventAt: Date.now.addingTimeInterval(-60), reviewCategory: .work).capture()
        try await f.store.addCapture(source)
        let state = await f.store.snapshot()
        let period = ReviewPeriod(start: Calendar.current.startOfDay(for: .now), end: Date.now)
        let report = try await WeeklyReviewEngine().generate(in: state, period: period, template: ReviewTemplate(kind: .work))
        let saved = try await f.store.commitWeeklyReport(report)
        guard let row = saved.digestRows.first else { throw Failure(text: "测试缺少周报条目") }
        _ = try await f.store.submitSummaryFeedback(target: .period(saved, item: row.item), text: "标题请明确写发布流程的步骤导航。")
        guard let job = try await f.store.claimSummaryFeedback(modelAvailable: true) else { throw Failure(text: "未领取周报反馈") }
        let json: [String: Any] = ["diagnosis": "expression", "message": "标题已调整。", "corrections": [], "rules": [],
            "changes": [["itemID": row.id, "remove": false, "title": "发布流程的步骤导航完成验收", "detail": "发布流程的步骤导航调整已经通过验收。", "section": row.item.section.rawValue, "sourceIDs": row.item.sourceIDs.map(\.uuidString)]]]
        let response = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        try await apply(f, job: job, response: response)
        let after = await f.store.snapshot()
        try check(after.weeklyReports.first?.digestRows.contains { $0.title == "发布流程的步骤导航完成验收" } == true && after.summaryFeedback[0].weeklyBefore != nil, "周期回顾没有应用修订或保留旧稿")
    }
}
