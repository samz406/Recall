import Foundation
import RecallKit

enum DailyReviewReminderVerification {
    private actor CompletionModel: LLMResponding {
        let reminderID: UUID
        var requests: [LLMRequest] = []
        init(_ id: UUID) { reminderID = id }
        func log() -> [LLMRequest] { requests }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            requests.append(request)
            let docs = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
            let doc = docs[0], id = doc["id"] as! String
            let quote = (doc["text"] as! String).components(separatedBy: "\n").last!
            let item: [String: Any] = ["section": "progress", "title": "Atlas 边界验证已提交", "detail": "本人已提交验收用例，原先的具体承诺已经履行。",
                "kind": "matter", "topic": "Atlas 边界验证", "owner": "user", "status": "completed", "explicitCommitment": false,
                "condition": NSNull(), "reminderID": reminderID.uuidString, "evidence": [["id": id, "quote": quote]]]
            let value: [String: Any] = ["overview": "本期完成 Atlas 边界验证。", "items": [item],
                "coverage": docs.map { ["id": $0["id"]!, "disposition": "used"] }]
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw VerificationError.failed(message) }
    }
    private static let now = Date(timeIntervalSince1970: 1_793_500_000)
    private static func source(_ text: String = "[聊天·自己] 我会提交 Atlas 验收报告。", at: Date = now.addingTimeInterval(-2 * 86_400), window: String = "Atlas") -> CaptureRecord {
        CaptureRecord(eventTemplate: .enterKeyTrigger, createdAt: at, sourceAppName: "Synthetic Chat", sourceBundleIdentifier: "example.synthetic.chat",
                      windowTitle: window, contentHash: UUID().uuidString, ocrText: text, textOrigin: .screenOCR)
    }
    private static func summary(_ source: CaptureRecord, title: String = "提交 Atlas 验收报告", action: Bool = true, linked: ReminderCandidate? = nil) throws -> DailySummary {
        let actionID = UUID()
        var knowledge = DailyItemKnowledge(topic: "Atlas 验收", kind: .matter, status: action ? "pending" : "completed", ownedByUser: true, quotes: [source.ocrText])
        knowledge.explicitCommitment = action
        knowledge.reminderID = linked?.id
        knowledge.reminderRevision = linked.map { SummaryFeedbackLearning.hash($0) }
        let item = DailySummaryItem(section: action ? .actions : .progress, title: title,
            detail: action ? "本人明确承诺，仍未完成；安排提醒时间需要用户确认。" : "本人已明确说明这个具体行动完成，保留后续证据。",
            evidenceIDs: [source.id], actionCandidateID: action ? actionID : nil, knowledge: knowledge)
        let todo = DailySummaryTodo(id: actionID, title: title, detail: item.detail, sourceCaptureIDs: [source.id], priority: .normal)
        var value = DailySummary(day: source.createdAt, createdAt: source.createdAt.addingTimeInterval(3_600), content: "", sourceCaptureIDs: [source.id],
            todos: action ? [todo] : [], generationKind: .cloud, items: [item])
        value.items = [item]
        value.modelCoverage = try JSONDecoder().decode(ModelReviewCoverage.self, from: Data(#"{"version":1,"sourceCount":1,"factCount":1,"uncertainBlockCount":0,"createdAt":0}"#.utf8))
        return value
    }
    private static func base() throws -> RecallState {
        let record = source()
        return RecallState(captures: [record], dailySummaries: [try summary(record)])
    }
    static func run() async throws {
        try projectionAndIdempotence()
        try ownershipAndBadRows()
        try namespacesAndHistory()
        try closureAndGuards()
        try invalidationAndPause()
        try await actualGenerationAndRollback()
        print("PASS: 12 daily-review reminder scenarios (Enter scope, zero extra calls, provenance, row isolation, idempotence, history, exact closure, roles, user races, source invalidation, pause and atomic rollback)")
    }
    private static func projectionAndIdempotence() throws {
        var state = try base()
        try expect(state.rules.first { $0.template == .enterKeyTrigger }?.participatesInReminders == false, "合成 Enter 规则应默认不参与原文深查")
        let first = DailyReviewReminderEngine.reconcile(&state, now: now)
        try expect(first.added == 1 && state.reminders.count == 1, "每日回顾错误地沿用了原文参与开关")
        let value = state.reminders[0]
        try expect(value.status == .proposed && value.dueAt == nil && value.scheduledAt == nil && value.recurrence == .none,
            "回顾候选被安排通知或补了默认时间")
        try expect(value.sourceCaptureIDs == [state.captures[0].id] && value.analysis?.evidence.first?.quote == state.captures[0].ocrText,
            "来源或原话没有保留")
        let encoded = try JSONEncoder().encode(state)
        var reopened = try JSONDecoder().decode(RecallState.self, from: encoded)
        let second = DailyReviewReminderEngine.reconcile(&reopened, now: now.addingTimeInterval(20))
        try expect(!second.changed && reopened.reminders == state.reminders, "重启重放产生了重复候选或覆盖了状态")
        let old = reopened.dailySummaries[0]
        var regenerated = try summary(reopened.captures[0]); regenerated.day = old.day
        reopened.dailySummaries = [regenerated]
        _ = DailyReviewReminderEngine.reconcile(&reopened, now: now.addingTimeInterval(30))
        try expect(reopened.reminders.count == 1 && reopened.reminders[0].id == value.id,
            "重新生成回顾丢失了原行动身份")
        let preserved = ReminderExtractor().merging([], into: reopened.reminders, now: now, revalidatedCaptureIDs: [state.captures[0].id])
        try expect(preserved == reopened.reminders, "手动深查的重验删除了回顾候选")
        var raw = value; raw.detail = "来自手动深查的不同描述"; raw.analysis = nil
        let merged = ReminderExtractor().merging([raw], into: reopened.reminders, now: now)
        try expect(merged == reopened.reminders, "手动深查覆盖了回顾候选的归属或依据")
    }
    private static func ownershipAndBadRows() throws {
        var state = try base()
        for text in ["[聊天·对方] 我会提交 Nova 报告。", "[聊天·自己] [内容·资料] 我会提交 Nova 报告。", "我会提交 Nova 报告。"] {
            let record = source(text, window: text)
            state.captures.append(record); state.dailySummaries.append(try summary(record, title: "提交 Nova 报告"))
        }
        var broken = state.dailySummaries[0].items[0]
        broken.id = UUID(); broken.actionCandidateID = UUID(); broken.knowledge?.quotes = ["不存在的原话"]
        state.dailySummaries[0].items.append(broken)
        state.dailySummaries[0].todos.append(DailySummaryTodo(id: broken.actionCandidateID!, title: broken.title, detail: broken.detail, priority: .normal))
        _ = DailyReviewReminderEngine.reconcile(&state, now: now)
        try expect(state.reminders.count == 1 && state.reminders[0].title.contains("Atlas"), "错误行使好行丢失，或对方/资料/未知归属变成本人待办")
        var legacy = try base(); legacy.dailySummaries[0].items[0].knowledge?.explicitCommitment = nil
        _ = DailyReviewReminderEngine.reconcile(&legacy, now: now)
        try expect(legacy.reminders.isEmpty, "旧回顾缺少明确承诺判断，却被批量追认为当前待办")
    }
    private static func namespacesAndHistory() throws {
        var state = try base()
        let other = source(window: "另一个客户")
        state.captures.append(other); state.dailySummaries.append(try summary(other))
        _ = DailyReviewReminderEngine.reconcile(&state, now: now)
        try expect(state.reminders.count == 2, "同标题不同对话的行动被错误合并")
        state.reminders[0].status = .dismissed; state.reminders[0].dismissedUntil = now.addingTimeInterval(86_400)
        state.reminderLearningProfile.reviewedDailyFingerprints = nil
        _ = DailyReviewReminderEngine.reconcile(&state, now: now)
        try expect(state.reminders.count == 2 && state.reminders[0].status == .dismissed, "重放让已忽略的行动复活")
    }
    private static func closedState(_ completionText: String = "[聊天·自己] Atlas 验收报告我已经提交完成。", linked: Bool = true) throws -> RecallState {
        var state = try base(); _ = DailyReviewReminderEngine.reconcile(&state, now: now.addingTimeInterval(-3_600))
        let done = source(completionText, at: now.addingTimeInterval(-86_400))
        state.captures.append(done)
        state.dailySummaries.append(try summary(done, title: "Atlas 验收报告已提交", action: false, linked: linked ? state.reminders[0] : nil))
        return state
    }
    private static func closureAndGuards() throws {
        var state = try closedState()
        let value = DailyReviewReminderEngine.reconcile(&state, now: now)
        try expect(value.completed == 1 && state.reminders[0].status == .completed && state.reminders[0].sourceCaptureIDs.count == 2,
            "后续每日回顾未形成可追溯完成闭环")
        let closedAt = state.reminders[0].closedAt
        _ = DailyReviewReminderEngine.reconcile(&state, now: now.addingTimeInterval(50))
        try expect(state.reminders[0].closedAt == closedAt, "重放改变了历史完成时间")
        for text in ["[聊天·对方] Atlas 验收报告我已经提交完成。", "Atlas 验收报告我已经提交完成。"] {
            var unsupported = try closedState(text)
            _ = DailyReviewReminderEngine.reconcile(&unsupported, now: now)
            try expect(unsupported.reminders[0].status == .proposed, "对方或未知说话人的完成误关了本人提醒")
        }
        var ambiguous = try closedState(linked: false)
        _ = DailyReviewReminderEngine.reconcile(&ambiguous, now: now)
        try expect(ambiguous.reminders[0].status == .proposed, "只凭相似标题或主题自动关闭")
        var edited = try closedState(); edited.reminders[0].detail += "用户刚刚改了要求"
        _ = DailyReviewReminderEngine.reconcile(&edited, now: now)
        try expect(edited.reminders[0].status == .proposed, "生成期间的用户操作被旧模型结果覆盖")
        var recurring = try closedState(); recurring.reminders[0].recurrence = .daily
        _ = DailyReviewReminderEngine.reconcile(&recurring, now: now)
        try expect(recurring.reminders[0].status == .proposed, "一次完成关闭了重复提醒")
        var confirmed = try closedState()
        confirmed.reminders[0].status = .scheduled; confirmed.reminders[0].scheduledAt = now
        confirmed.dailySummaries[1].items[0].knowledge?.reminderRevision = SummaryFeedbackLearning.hash(confirmed.reminders[0])
        _ = DailyReviewReminderEngine.reconcile(&confirmed, now: now)
        try expect(confirmed.reminders[0].status == .completed, "经用户安排的单次提醒没有随本人完成证据闭环")
    }
    private static func invalidationAndPause() throws {
        var state = try closedState(); _ = DailyReviewReminderEngine.reconcile(&state, now: now)
        state.dailySummaries.removeLast()
        _ = DailyReviewReminderEngine.reconcile(&state, now: now.addingTimeInterval(1))
        try expect(state.reminders[0].status == .proposed && state.reminders[0].scheduledAt == nil, "完成依据撤回后仍自动完成或重排通知")
        var changed = try base(); _ = DailyReviewReminderEngine.reconcile(&changed, now: now)
        changed.captures[0].correctedText = "[聊天·对方] 这是另一位同事的承诺。"
        _ = DailyReviewReminderEngine.reconcile(&changed, now: now)
        try expect(changed.reminders.isEmpty, "被纠正的原话仍支撑待确认候选")
        var blocked = try base(); blocked.privacy.excludedBundleIdentifiers.insert("example.synthetic.chat")
        _ = DailyReviewReminderEngine.reconcile(&blocked, now: now)
        try expect(blocked.reminders.isEmpty, "隐私排除仍进入提醒")
        var paused = try base(); paused.reminderLearningProfile.reviewDiscoveryEnabled = false
        _ = DailyReviewReminderEngine.reconcile(&paused, now: now)
        try expect(paused.reminders.isEmpty, "关闭后仍投影新候选")
        paused.reminderLearningProfile.reviewDiscoveryEnabled = true
        _ = DailyReviewReminderEngine.reconcile(&paused, now: now)
        try expect(paused.reminders.count == 1, "重新启用没有处理已保存的回顾")
    }
    private static func actualGenerationAndRollback() async throws {
        let record = source(at: Date.now.addingTimeInterval(-2 * 86_400))
        let duplicate = source(record.ocrText, at: record.createdAt.addingTimeInterval(30))
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-review-reminders-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        var state = RecallState(captures: [record, duplicate], privacy: PrivacySettings(cloudUseEnabled: true),
            llmConfiguration: LLMConfiguration(provider: .openAICompatible, baseURLString: "https://model.invalid/v1", model: "synthetic", apiKey: "synthetic-not-a-key"))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: storage.stateURL)
        let store = try verificationStore(storage: storage)
        let model = DirectDailyReviewVerification.Model("action")
        let period = ReviewPeriod(start: record.createdAt.addingTimeInterval(-60), end: record.createdAt.addingTimeInterval(3_600))
        let output = try await store.generateDirectDailyReview(day: record.createdAt, period: period, responder: model)
        let calls = await model.log(), saved = await store.snapshot()
        try expect(calls.count == 1 && output.metrics.modelCalls == 1 && saved.reminders.count == 1 && output.reminders.added == 1,
            "真实回顾入口没有在一次调用中保存回顾与提醒")
        try expect(Set(saved.reminders[0].sourceCaptureIDs) == Set([record.id, duplicate.id]),
            "相同应用内的重复 OCR 去重后丢失了后续截图来源")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let reloaded = try decoder.decode(RecallState.self, from: encoder.encode(saved))
        try expect(SummaryFeedbackLearning.hash(saved.dailySummaries[0]) == SummaryFeedbackLearning.hash(reloaded.dailySummaries[0]),
            "新增来源版本字段导致重启后回顾校验值不稳定")
        let next = source("[聊天·自己] Atlas 边界验证我已经补齐并提交给评审。", at: Date.now.addingTimeInterval(-86_400))
        try await store.addCapture(next)
        let completion = CompletionModel(saved.reminders[0].id)
        let closed = try await store.generateDirectDailyReview(day: next.createdAt,
            period: ReviewPeriod(start: next.createdAt.addingTimeInterval(-60), end: next.createdAt.addingTimeInterval(3_600)), responder: completion)
        let linkedRequests = await completion.log(), completed = await store.snapshot()
        try expect(linkedRequests.count == 1 && linkedRequests[0].question.contains(saved.reminders[0].id.uuidString),
            "后续真实回顾没有把已有待办作为关联元数据发送")
        try expect(closed.reminders.completed == 1 && completed.reminders[0].status == .completed,
            "后续真实回顾未完成原提醒")
        try expect(Set(completed.reminders[0].sourceCaptureIDs) == Set([record.id, duplicate.id, next.id]),
            "完成闭环没有保留两日全部来源截图")
        // The same words in two different conversations are separate model inputs, not duplicate screenshots.
        let separate = source(record.ocrText, at: record.createdAt.addingTimeInterval(60), window: "Nova")
        let scopeStorage = try RecallStorage(rootURL: storage.rootURL.appendingPathComponent("scopes"))
        state.captures.append(separate)
        try encoder.encode(state).write(to: scopeStorage.stateURL)
        let scopedStore = try verificationStore(storage: scopeStorage), scopedModel = DirectDailyReviewVerification.Model("action")
        let scoped = try await scopedStore.generateDirectDailyReview(day: record.createdAt, period: period, responder: scopedModel)
        let scopedRequests = await scopedModel.log()
        let documents = try JSONSerialization.jsonObject(with: Data(scopedRequests[0].context[0].ocrText.utf8)) as! [[String: Any]]
        try expect(documents.count == 2 && scoped.summary.items[0].evidenceIDs == [separate.id],
            "不同对话的同一句话被合并，或无关截图被挂到同一提醒")
        // A local sync write failure must roll back candidates and its durable journal together.
        state = try base()
        let other = try RecallStorage(rootURL: storage.rootURL.appendingPathComponent("failure"))
        try encoder.encode(state).write(to: other.stateURL)
        let failed = try verificationStore(storage: other)
        let before = await failed.snapshot()
        try FileManager.default.removeItem(at: other.stateURL)
        try FileManager.default.createDirectory(at: other.stateURL, withIntermediateDirectories: false)
        do { try await failed.syncDailyReviewReminders(); throw VerificationError.failed("写入失败被忽略") }
        catch let e as VerificationError { throw e } catch {}
        let after = await failed.snapshot()
        try expect(after.reminders == before.reminders && after.reminderLearningProfile == before.reminderLearningProfile, "保存失败没有原子回滚提醒与检查点")
    }
}
