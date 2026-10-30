import Foundation
import RecallKit

/// Synthetic responses exercise contracts, not the accuracy of a production model.
enum ModelReminderDiscoveryVerification {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(errorDescription: message) }
    }
    actor Model: LLMResponding {
        var mode: String
        var requests: [LLMRequest] = []
        let onAudit: (@Sendable () async throws -> Void)?
        init(_ mode: String = "valid", onAudit: (@Sendable () async throws -> Void)? = nil) { self.mode = mode; self.onAudit = onAudit }
        func log() -> [LLMRequest] { requests }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            requests.append(request)
            if mode == "network" || (mode == "second-group" && requests.count >= 3) { throw URLError(.notConnectedToInternet) }
            if mode == "slow" { try await Task.sleep(for: .seconds(30)) }
            if mode == "malformed" { return LLMAnswer(content: "{broken", citedCaptureIDs: []) }
            let input = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [String: Any]
            let sources = input["sources"] as! [[String: Any]]
            let primary = sources.flatMap { $0["blocks"] as! [[String: Any]] }.filter { $0["contextOnly"] as? Bool != true }
            let pending = input["pending"] as! [[String: Any]]
            let object: [String: Any]
            if request.purpose == .reminderDiscoveryAudit {
                let raw = request.question.components(separatedBy: "草稿：\n").last!
                let draft = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
                object = ["actionIDs": mode == "reject" ? [] : (draft["actions"] as! [[String: Any]]).map { $0["id"]! },
                    "reminderIDs": (draft["resolutions"] as! [[String: Any]]).map { $0["reminderID"]! },
                    "checkedBlockIDs": primary.map { $0["id"]! }, "missedBlockIDs": []]
            } else {
                guard request.purpose == .reminderDiscovery else { throw Failure(errorDescription: "提醒误用逐条整理请求") }
                var actions: [[String: Any]] = [], resolutions: [[String: Any]] = []
                var used = Set<String>(), resolved = Set<String>()
                for (i, block) in primary.enumerated() {
                    let text = block["text"] as! String, id = block["id"] as! String
                    if text.contains("清单已提交"), let task = pending.first {
                        resolutions.append(["reminderID": task["id"]!, "status": "completed",
                            "evidence": [["blockID": id, "quote": "清单已提交"]]])
                        resolved.insert(id)
                    } else if text.contains("验收清单") && (text.contains("我会") || text.contains("请你")) {
                        let quote = mode == "quote" ? "原文不存在的承诺" : (text.contains("请你") ? "请你周五前整理验收清单" : "我会整理验收清单")
                        var action: [String: Any] = ["id":"a\(i)", "existingID": mode == "existing" ? (pending.first?["id"] ?? NSNull()) : NSNull(),
                            "title":"整理合成项目验收清单", "detail":"核对合成项目的验收边界后准备清单。", "owner":"user",
                            "kind":text.contains("请你") ? "request":"commitment", "status":"pending",
                            "condition":mode == "conditional" ? "完成评审后":NSNull(), "deadline":NSNull(),
                            "recurrence":"none", "evidence":[["blockID":id,"quote":quote]]]
                        if mode == "date" || mode == "invent-date" {
                            action["deadline"] = ["text":"2026年11月2日","evidence":["blockID":id,"quote":mode == "date" ? "2026年11月2日":"伪造2026年11月2日"]]
                        }
                        actions.append(action); used.insert(id)
                    }
                }
                let coverage: [[String: Any]] = primary.map {
                    let id = $0["id"] as! String
                    return ["blockID":id,"disposition": mode == "uncertain" ? "uncertain" : (used.contains(id) ? "action":(resolved.contains(id) ? "resolution":"background"))]
                }
                object = ["actions": mode == "uncertain" ? []:actions,"resolutions":resolutions,"coverage":mode == "coverage" ? []:coverage]
            }
            if request.purpose == .reminderDiscoveryAudit { try await onAudit?() }
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    static func record(_ text: String, offset: Double = 0, origin: CaptureTextOrigin? = nil) -> CaptureRecord {
        CaptureRecord(eventTemplate: .manualMoment, createdAt: Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970) - 60 + offset),
            sourceAppName: "合成聊天", sourceBundleIdentifier: "test.chat", windowTitle: "合成会话",
            contentHash: UUID().uuidString, ocrText: text, textOrigin: origin)
    }
    static func state(_ records: [CaptureRecord], reminders: [ReminderCandidate] = []) -> RecallState {
        RecallState(captures: records, reminders: reminders, privacy: PrivacySettings(cloudUseEnabled: true),
            llmConfiguration: LLMConfiguration(provider: .openAICompatible, baseURLString: "https://model.invalid/v1", model: "synthetic", apiKey: "synthetic-not-a-key"))
    }
    static func store(_ value: RecallState) throws -> (FileMemoryStore, RecallStorage) {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-reminder-model-" + UUID().uuidString))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: storage.stateURL)
        return (try FileMemoryStore(storage: storage), storage)
    }
    static func run() async throws {
        try await semanticPath(); try await ownership(); try await falsePositives(); try await validation()
        try deadlines(); try await stateReconciliation(); try await failureAndCancellation()
        try await incremental(); try await partialResume(); try await optIn(); try await changedSources()
        try await privacy(); try legacy(); try await persistenceFailure()
    }
    static func semanticPath() async throws {
        let source = record("[聊天·自己] 我会整理验收清单"), model = Model()
        let result = try await ModelReminderDiscovery().analyze([source], in: state([source]), responder: model)
        try check(result.candidates.count == 1 && result.candidates[0].analysis?.basis == "你明确承诺的行动", "模型依据未保存")
        let calls = await model.log()
        try check(calls.map(\.purpose) == [.reminderDiscovery,.reminderDiscoveryAudit], "候选未经模型提取和独立核对")
        try check(result.candidates[0].dueAt == nil && result.candidates[0].status == .proposed, "无时间事项被补时间或自动安排")
        let anchor = "[聊天·自己] 我会整理验收清单，并核对所有输入输出的边界条件。"
        let current = record(anchor), adjacent = record(anchor + "\n[聊天·对方] 这份合成清单需要保留输入校验依据。", offset:-20)
        let unrelated = record("[聊天·自己] 另一个会话正在讨论完全无关的内容。", offset:-10)
        let contextState = state([current,adjacent,unrelated]), contextModel = Model()
        let neighbours = ModelReminderDiscovery().contextSources(for:[current],in:contextState)
        try check(neighbours.map(\.id) == [adjacent.id], "仅凭相同应用或窗口拼接了无关会话")
        _ = try await ModelReminderDiscovery().analyze([current],in:contextState,responder:contextModel)
        let contextCalls = await contextModel.log()
        try check(contextCalls[0].context[0].ocrText.contains("输入校验依据") && !contextCalls[0].context[0].ocrText.contains("完全无关"), "模型未获得限定的聊天上下文")
    }
    static func ownership() async throws {
        let request = record("[聊天·对方] 请你周五前整理验收清单吧"), unknown = record("[聊天·角色未知] 我会整理验收清单")
        let engine = ModelReminderDiscovery()
        let first = try await engine.analyze([request], in: state([request]), responder: Model())
        try check(first.candidates.count == 1 && first.candidates[0].analysis?.basis == "对方向你提出的请求", "明确请求被漏掉或冒充承诺")
        let second = try await engine.analyze([unknown], in: state([unknown]), responder: Model())
        try check(second.candidates.isEmpty, "未知说话人变成用户")
        let source = record("[聊天·自己] 我会整理验收清单")
        let conditional = try await engine.analyze([source], in: state([source]), responder: Model("conditional"))
        try check(conditional.candidates.isEmpty, "条件未满足也生成任务")
    }
    static func falsePositives() async throws {
        let texts = ["[内容·资料] Leader的目标不是完成任务","[内容·系统] 网络异常，请检查网络后再试","发布日期：2026年9月18日","提交记录：0123456","[聊天·对方] 下一步建议优化缓存","[聊天·自己] 验收清单已完成"]
        let records = texts.map { record($0) }, model = Model()
        let result = try await ModelReminderDiscovery().analyze(records, in: state(records), responder: model)
        try check(result.candidates.isEmpty, "资料、提示或完成态变成待办")
        let calls = await model.log(); try check(calls.count == 1, "空结果进行了无用二次请求")
        let source = record("[聊天·自己] 我会整理验收清单")
        let rejected = try await ModelReminderDiscovery().analyze([source], in: state([source]), responder: Model("reject"))
        try check(rejected.candidates.isEmpty, "审阅否决未生效")
    }
    static func validation() async throws {
        let source = record("[聊天·自己] 我会整理验收清单")
        for mode in ["quote","coverage","invent-date","malformed"] {
            let model = Model(mode)
            do { _ = try await ModelReminderDiscovery().analyze([source], in: state([source]), responder: model); throw Failure(errorDescription:"无效结果成功："+mode) }
            catch is ReminderDiscoveryError {}
            let calls = await model.log(); try check(calls.count == 2, "格式/证据失败应只修正一次")
        }
    }
    static func deadlines() throws {
        let source = record("合成时间", origin: .userInput), ocr = record("合成旧聊天")
        for text in ["2026年11月2日","周五前","发布日期：2026年9月18日","2026年2月30日15:00","2026年11月2日25:70"] {
            try check(ReminderDeadlineResolver.resolve(text, source: source) == nil, "缺时刻或无效日期被补为提醒："+text)
        }
        let chinese = ReminderDeadlineResolver.resolve("2026年11月2日下午三点半", source: ocr)
        try check(chinese.map { Calendar.current.component(.hour, from:$0) == 15 && Calendar.current.component(.minute, from:$0) == 30 } == true, "中文绝对时间未解析")
        try check(ReminderDeadlineResolver.resolve("明天下午3点", source:ocr) == nil, "历史聊天相对时间使用了采集日期")
        try check(ReminderDeadlineResolver.resolve("明天下午3点", source:source) != nil, "实际输入的明确相对时间未解析")
        try check(ReminderDeadlineResolver.resolve("3小时后", source:source).map { abs($0.timeIntervalSince(source.createdAt) - 10_800) < 1 } == true, "实际输入的相对小时未解析")
    }
    static func stateReconciliation() async throws {
        let before = record("[聊天·自己] 我会整理验收清单"), after = record("[聊天·自己] 验收清单已提交", offset:20)
        let old = ReminderCandidate(title:"整理合成项目验收清单", detail:"原有候选", sourceCaptureIDs:[before.id], confidence:0.7, createdAt:before.createdAt)
        let manual = ReminderCandidate(title:"手动安排的合成事情", detail:"保留", confidence:1, status:.scheduled, createdAt:before.createdAt, origin:.manual)
        let (memory, storage) = try store(state([before,after], reminders:[old,manual])); defer { try? FileManager.default.removeItem(at:storage.rootURL) }
        _ = try await memory.discoverRemindersUsingModel(responder:Model())
        let saved = await memory.snapshot()
        try check(saved.reminders.first { $0.id == old.id }?.status == .completed, "后续证据未关闭旧候选")
        try check(saved.reminders.first { $0.id == old.id }?.sourceCaptureIDs.contains(after.id) == true, "关闭状态没有关联后续证据")
        try check(saved.reminders.first { $0.id == manual.id } == manual, "自动分析改动已安排或手动提醒")
        let source = record("[聊天·自己] 我会整理验收清单 2026年11月2日")
        let result = try await ModelReminderDiscovery().analyze([source], in:state([source]), responder:Model("date"))
        try check(result.candidates.first?.dueAt == nil && result.candidates.first?.detail.contains("2026年11月2日") == true, "期限丢失或补了9点")
    }
    static func failureAndCancellation() async throws {
        let source = record("[聊天·自己] 我会整理验收清单")
        let old = ReminderCandidate(title:"原有合成提醒", detail:"保留", sourceCaptureIDs:[source.id], confidence:0.6, createdAt:source.createdAt)
        let (memory, storage) = try store(state([source], reminders:[old])); defer { try? FileManager.default.removeItem(at:storage.rootURL) }
        do { _ = try await memory.discoverRemindersUsingModel(responder:Model("network")); throw Failure(errorDescription:"网络错误未抛出") } catch is URLError {}
        let failed = await memory.snapshot()
        try check(failed.reminders == [old] && failed.reminderDiscoveryCheckpoint.processedCaptureHashes.isEmpty && failed.reminderDiscoveryCheckpoint.failureReason != nil, "失败冒充空结果或覆盖旧候选")
        let model = Model("slow"), task = Task { try await memory.discoverRemindersUsingModel(responder:model) }
        for _ in 0..<100 { if !(await model.log()).isEmpty { break }; try await Task.sleep(for:.milliseconds(5)) }
        task.cancel()
        do { _ = try await task.value; throw Failure(errorDescription:"停止未生效") } catch is CancellationError {}
        let cancelled = await memory.snapshot(); try check(cancelled.reminders == [old], "停止后覆盖旧提醒")
    }
    static func incremental() async throws {
        let first = record("[聊天·自己] 我会整理验收清单"); var second = first; second.id = UUID()
        let (memory, storage) = try store(state([first,second])); defer { try? FileManager.default.removeItem(at:storage.rootURL) }
        let model = Model(), run = try await memory.discoverRemindersUsingModel(responder:model)
        try check(run.analyzedRecords == 2 && run.added == 1, "重复截图未去重或漏记签名")
        let calls = await model.log()
        try check(calls[0].context[0].ocrText.components(separatedBy:"我会整理验收清单").count == 2, "重复发送相同截图")
        let again = Model(), next = try await memory.discoverRemindersUsingModel(responder:again)
        let nextCalls = await again.log(); try check(next.analyzedRecords == 0 && nextCalls.isEmpty, "未变化记录重复调用模型")
        let priorIDs = Set((await memory.snapshot()).reminders.map(\.id))
        _ = try await memory.discoverRemindersUsingModel(force:true,responder:Model("uncertain"))
        let uncertain = await memory.snapshot()
        try check(Set(uncertain.reminders.map(\.id)) == priorIDs, "不确定的分析直接删除了已有候选")
    }
    static func partialResume() async throws {
        let records = (0..<3).map { record("[聊天·自己] 我会整理验收清单\n" + String(repeating:"合成背景资料。",count:1_500), offset:Double($0)) }
        let (memory, storage) = try store(state(records)); defer { try? FileManager.default.removeItem(at:storage.rootURL) }
        do { _ = try await memory.discoverRemindersUsingModel(responder:Model("second-group")); throw Failure(errorDescription:"预期第二批失败") } catch is URLError {}
        let saved = await memory.snapshot()
        try check(saved.reminderDiscoveryCheckpoint.processedCaptureHashes.count == 1 && !saved.reminders.isEmpty, "成功批次未保留")
        _ = try await memory.discoverRemindersUsingModel(responder:Model())
        let final = await memory.snapshot(); try check(final.reminderDiscoveryCheckpoint.processedCaptureHashes.count == 3, "重试未完成余下记录")
    }
    static func optIn() async throws {
        let source = record("[聊天·自己] 我会整理验收清单")
        let (memory, storage) = try store(state([source])); defer { try? FileManager.default.removeItem(at:storage.rootURL) }
        let model = Model()
        do { _ = try await memory.discoverRemindersUsingModel(automatic:true, responder:model); throw Failure(errorDescription:"默认后台发出了请求") } catch ReminderDiscoveryError.unavailable {}
        let calls = await model.log(); try check(calls.isEmpty, "未启用后台发现就调用模型")
        try await memory.setAutomaticReminderDiscovery(true)
        _ = try await memory.discoverRemindersUsingModel(automatic:true, responder:model)
        let reopened = try FileMemoryStore(storage:storage), saved = await reopened.snapshot()
        try check(saved.reminderLearningProfile.automaticDiscovery == true && saved.reminders.first?.analysis != nil, "设置或模型依据未持久化")
    }
    static func changedSources() async throws {
        for mode in ["privacy","configuration","rule","application","source","automatic","dismiss"] {
            let source = record("[聊天·自己] 我会整理验收清单")
            var value = state([source]); value.reminderLearningProfile.automaticDiscovery = true
            let old = ReminderCandidate(title:"整理合成项目验收清单", detail:"用户状态优先", sourceCaptureIDs:[source.id], confidence:0.8, createdAt:source.createdAt)
            if mode == "dismiss" { value.reminders = [old] }
            let (memory, storage) = try store(value)
            defer { try? FileManager.default.removeItem(at:storage.rootURL) }
            let model = Model(onAudit: {
                switch mode {
                case "privacy":
                    var privacy = (await memory.snapshot()).privacy; privacy.cloudUseEnabled = false
                    try await memory.updatePrivacy(privacy)
                case "configuration":
                    var config = (await memory.snapshot()).llmConfiguration; config.model = "changed"
                    try await memory.updateLLMConfiguration(config)
                case "rule":
                    var rules = (await memory.snapshot()).rules
                    for i in rules.indices { rules[i].participatesInReminders = false }
                    try await memory.updateRules(rules)
                case "application":
                    if let choice = ReminderSourceChoice(capture:source) { try await memory.setReminderApplication(choice,disabled:true) }
                case "source": _ = try await memory.deleteCapture(id:source.id)
                case "automatic": try await memory.setAutomaticReminderDiscovery(false)
                default:
                    var dismissed = old; dismissed.status = .dismissed; dismissed.updatedAt = .now
                    dismissed.dismissedUntil = Date.now.addingTimeInterval(30 * 86_400)
                    try await memory.updateReminder(dismissed)
                }
            })
            do {
                _ = try await memory.discoverRemindersUsingModel(automatic:mode == "automatic",responder:model)
                if mode != "dismiss" { throw Failure(errorDescription:"输入变化未中止："+mode) }
            } catch ReminderDiscoveryError.changed {}
            let saved = await memory.snapshot()
            try check(!saved.reminders.contains { $0.status == .proposed }, "旧请求绕过了最新设置或处理结果："+mode)
        }
    }
    static func privacy() async throws {
        var source = record("[聊天·自己] 我会整理验收清单，联系 fake@example.invalid")
        source.imageRelativePath = "Screenshots/synthetic.png"
        let model = Model(); _ = try await ModelReminderDiscovery().analyze([source], in:state([source]), responder:model)
        let calls = await model.log()
        try check(calls.allSatisfy { !$0.context[0].ocrText.contains("fake@example.invalid") && $0.context[0].imageRelativePath == nil }, "模型输入包含未脱敏文本或截图")
    }
    static func legacy() throws {
        let data = Data(#"{"processedCaptureHashes":{},"eligibleRecordCount":0,"analyzedRecordCount":0,"discoveredCount":0}"#.utf8)
        let old = try JSONDecoder().decode(ReminderDiscoveryCheckpoint.self, from:data)
        try check(old.lastAttemptAt == nil && old.failureReason == nil, "旧检查点不兼容")
        try check(ReminderLearningProfile().automaticDiscovery != true, "旧档案默认开启后台分析")
    }
    static func persistenceFailure() async throws {
        let source = record("[聊天·自己] 我会整理验收清单")
        let (memory, storage) = try store(state([source])); defer { try? FileManager.default.removeItem(at:storage.rootURL) }
        try FileManager.default.removeItem(at:storage.stateURL); try FileManager.default.createDirectory(at:storage.stateURL,withIntermediateDirectories:false)
        do { _ = try await memory.discoverRemindersUsingModel(responder:Model()); throw Failure(errorDescription:"预期写入失败") }
        catch let error as Failure { throw error } catch {}
        let saved = await memory.snapshot(); try check(saved.reminders.isEmpty && saved.reminderDiscoveryCheckpoint.processedCaptureHashes.isEmpty, "写入失败未回滚")
    }
}
