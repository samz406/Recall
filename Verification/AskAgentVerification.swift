import Foundation
import RecallKit

/// Scripted model decisions for the cloud 问一问 loop. No network and no real screen text.
@MainActor
enum AskAgentVerification {
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }

    static func run() async throws {
        try streamLines()
        try await directAnswerIncludesVerification()
        try await toolsThenAnswerDropFakeCitations()
        try await unauthorizedReadsStayLocal()
        try await tooManyCallsForceAnAnswer()
        try await roundCapForcesAnAnswer()
        try await budgetForcesAnAnswer()
        try await invalidPlanFallsBack()
        try await deletedSourceVoidsTheAnswer()
        try await cancellationStopsTheRequest()
        try await greetingSkipsRetrieval()
        try await conversationalReplySkipsSearch()
        try await statusPrecedesLookup()
        try await weekOverviewSkipsPlanning()
        try await reviewEvidenceKeepsOwnText()
        try await yesterdayIgnoresPriorAnswerAndToday()
        try await commitmentsRequireUserEvidence()
        try await screenTextNeverReachesTheAnswer()
        try await dayWithoutReviewAsksToGenerate()
        try await recentSpanTopicAndCategorySynthesis()
        try await topicScopeKeepsDailyReviewItems()
        try await plannerFormattingAndGroundingResilience()
        try await middaySummaryRefreshesTodayAutomatically()
        try await scopedMultiTurnMetaFollowUpAndDeduplication()
        print("PASS: 24 ask-agent scenarios (stream, direct answer, tools, refusal, budget, fallback, deletion, cancellation, greeting, reply, status, synthesis, topic scope, grounding, midday refresh, multi-turn meta follow-up)")
    }

    private static func streamLines() throws {
        var text = ""
        let first = "data: " + json(["choices": [["delta": ["content": "你"]]]])
        let second = "data: " + json(["choices": [["delta": ["content": "好"]]]])
        try expect(!ModelStreamDecoder.consume(first, into: &text), "流式片段被当成结束")
        _ = ModelStreamDecoder.consume(second, into: &text)
        try expect(text == "你好", "OpenAI 兼容流没有拼上文字")
        try expect(ModelStreamDecoder.consume("data: [DONE]", into: &text), "OpenAI 结束标记没有收束")
        var anthropic = ""
        let delta = "data: " + json(["type": "content_block_delta", "delta": ["type": "text_delta", "text": "周"]])
        _ = ModelStreamDecoder.consume(delta, into: &anthropic)
        try expect(anthropic == "周", "Anthropic 兼容流没有取出文字")
        let stop = "data: " + json(["type": "message_stop"])
        try expect(ModelStreamDecoder.consume(stop, into: &anthropic), "Anthropic 结束标记没有收束")
    }

    private static func directAnswerIncludesVerification() async throws {
        let (storage, store, capture) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let before = await store.snapshot().memoryKnowledge.updatedAt
        let script = ScriptedAskModel { request in
            let body = #"{"answer":"已经记下 AtlasScopeToken","citations":[""# + capture.id.uuidString + #""]}"#
            return LLMAnswer(content: body, citedCaptureIDs: [])
        }
        var steps: [String] = []
        let answer = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script, onStep: { name, _ in steps.append(name) })
        let purposes = await script.recorded().map(\.purpose)
        // 方案 B：普通事实由本地预检放行，不再调用模型核对。
        try expect(purposes == [.chatPlanning], "普通事实不应再调用模型核对")
        try expect(answer.content.contains("AtlasScopeToken") && answer.citations == [capture.id], "第一轮回答没有保留已出现的来源")
        let after = await store.snapshot().memoryKnowledge.updatedAt
        try expect(after == before, "提问重算了记忆账本")
        try expect(steps.contains("analysis") && steps.allSatisfy { !$0.contains("AtlasScopeToken") }, "耗时日志写入了问题原文")
    }

    private static func toolsThenAnswerDropFakeCitations() async throws {
        let (storage, store, capture) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let fake = UUID()
        let script = ScriptedAskModel { request in
            if request.purpose == .chatPlanning, !request.question.contains("已读取的工具结果") {
                return LLMAnswer(content: #"{"calls":[{"tool":"search_records","args":{"query":"AtlasScopeToken"}}]}"#, citedCaptureIDs: [])
            }
            let body = #"{"answer":"AtlasScopeToken 已找到 \#(fake.uuidString)","citations":[""# + capture.id.uuidString + #"",""# + fake.uuidString + #""]}"#
            return LLMAnswer(content: body, citedCaptureIDs: [])
        }
        let answer = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script)
        try expect(answer.citations == [capture.id] && !answer.content.contains(fake.uuidString), "伪造的来源仍留在回答里")
        let purposes = await script.recorded().map(\.purpose)
        try expect(purposes == [.chatPlanning, .chatPlanning], "检索后的普通回答不应再走核对请求")
    }

    private static func unauthorizedReadsStayLocal() async throws {
        let (storage, store, visible) = try await fixture("AtlasScopeToken 可见内容")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let hidden = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "合成", sourceBundleIdentifier: "example.visible",
            contentHash: UUID().uuidString, ocrText: "NOT-MINE-SECRET-TOKEN", textOrigin: .userInput)
        let excluded = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "合成", sourceBundleIdentifier: "example.secret",
            contentHash: UUID().uuidString, ocrText: "EXCLUDED-SECRET-TOKEN", textOrigin: .userInput)
        try await store.addCapture(hidden)
        try await store.addCapture(excluded)
        try await store.saveMatterCorrection(MatterCorrection(evidenceIDs: [hidden.id], kind: .notMine))
        var privacy = await store.snapshot().privacy
        privacy.excludedBundleIdentifiers.insert("example.secret")
        privacy.cloudUseEnabled = true
        try await store.updatePrivacy(privacy)
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .openAICompatible, baseURLString: "https://example.test/v1", model: "test", apiKey: "test-key"))
        let review = DailySummary(day: .now, content: "REVIEW-SECRET-TOKEN", sourceCaptureIDs: [visible.id], todos: [], generationKind: .localFallback)
        try await store.upsertDailySummary(review)
        let unknown = UUID()
        let script = ScriptedAskModel { request in
            if request.purpose != .chatPlanning || request.question.contains("已读取的工具结果") {
                return LLMAnswer(content: #"{"answer":"没有这些内容","citations":[]}"#, citedCaptureIDs: [])
            }
            let calls: [String: Any] = ["calls": [
                ["tool": "read_records", "args": ["ids": [hidden.id.uuidString, excluded.id.uuidString, unknown.uuidString]]],
                ["tool": "get_daily_reviews", "args": ["from": "2020-01-01", "to": "2020-03-01"]]
            ]]
            return LLMAnswer(content: json(calls), citedCaptureIDs: [])
        }
        _ = try await MemoryAssistant(store: store).ask("读取指定记录", model: script)
        let toolText = await script.recorded().dropFirst().map(\.question).joined(separator: "\n")
        try expect(!toolText.contains("NOT-MINE-SECRET-TOKEN") && !toolText.contains("EXCLUDED-SECRET-TOKEN") && !toolText.contains("REVIEW-SECRET-TOKEN"), "越权读取把正文交了出去")
        try expect(toolText.contains("已拒绝"), "越权请求没有被拒绝")
    }

    private static func tooManyCallsForceAnAnswer() async throws {
        let (storage, store, capture) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let plan = json(["calls": (0..<7).map { _ in ["tool": "read_records", "args": ["ids": [capture.id.uuidString]]] }])
        let script = ScriptedAskModel { request in
            if request.purpose == .chatPlanning { return LLMAnswer(content: plan, citedCaptureIDs: []) }
            return LLMAnswer(content: "已根据现有材料回答", citedCaptureIDs: [])
        }
        var tools: [String] = []
        let answer = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script, onStep: { name, _ in if name.hasPrefix("tool:") { tools.append(name) } })
        let purposes = await script.recorded().map(\.purpose)
        try expect(tools.count == 6 && purposes.filter { $0 == .chatPlanning }.count == 1 && purposes.last == .chat, "超过每轮调用上限后仍继续决定")
        try expect(answer.citations == [capture.id] && !answer.content.isEmpty, "强制回答没有关联到已读来源")
    }

    private static func roundCapForcesAnAnswer() async throws {
        let (storage, store, _) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let script = ScriptedAskModel { request in
            if request.purpose == .chatPlanning {
                return LLMAnswer(content: #"{"calls":[{"tool":"list_days","args":{"from":"2026-11-01","to":"2026-11-01"}}]}"#, citedCaptureIDs: [])
            }
            return LLMAnswer(content: "轮数到了，按已有材料回答", citedCaptureIDs: [])
        }
        var tools: [String] = []
        _ = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script, onStep: { name, _ in if name.hasPrefix("tool:") { tools.append(name) } }, limits: AskLimits(maxRounds: 2))
        let purposes = await script.recorded().map(\.purpose)
        try expect(purposes.filter { $0 == .chatPlanning }.count == 2 && tools.count == 2 && purposes.last == .chat, "超过轮数后仍继续要工具")
    }

    private static func budgetForcesAnAnswer() async throws {
        let long = "HEAD-TOKEN " + String(repeating: "字", count: 500) + " TAIL-SECRET"
        let (storage, store, capture) = try await fixture(long)
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let script = ScriptedAskModel { request in
            if request.purpose == .chatPlanning {
                return LLMAnswer(content: json(["calls": [["tool": "read_records", "args": ["ids": [capture.id.uuidString]]]]]), citedCaptureIDs: [])
            }
            return LLMAnswer(content: "材料已截断后的回答", citedCaptureIDs: [])
        }
        _ = try await MemoryAssistant(store: store).ask("HEAD-TOKEN", model: script, limits: AskLimits(maxResultCharacters: 80))
        let recorded = await script.recorded()
        let sent = recorded.filter { $0.purpose == .chat || $0.purpose == .answerVerification }.map { $0.question + ($0.supplementaryContext ?? "") + $0.context.map(\.ocrText).joined() }.joined()
        try expect(!sent.contains("TAIL-SECRET"), "超出字数预算后仍把后文发给模型")
        try expect(recorded.last?.purpose == .chat, "裁剪后的原文片段没有走到最终回答")
    }

    private static func invalidPlanFallsBack() async throws {
        let (storage, store, _) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let script = ScriptedAskModel { request in
            if request.purpose == .chatPlanning { return LLMAnswer(content: "不是 JSON", citedCaptureIDs: []) }
            return LLMAnswer(content: "回退后的摘录", citedCaptureIDs: [])
        }
        let answer = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script)
        try expect(!answer.content.isEmpty && !answer.citations.isEmpty, "格式错误没有退回原来的回答")
        let purposes = await script.recorded().map(\.purpose)
        try expect(purposes.contains(.chatPlanning) && purposes.contains(.chat), "回退没有再走原来的回答请求")
    }

    private static func deletedSourceVoidsTheAnswer() async throws {
        let (storage, store, capture) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let script = ScriptedAskModel { request in
            _ = try await store.deleteCapture(id: capture.id)
            let body = #"{"answer":"AtlasScopeToken 还在","citations":[""# + capture.id.uuidString + #""]}"#
            return LLMAnswer(content: body, citedCaptureIDs: [])
        }
        do {
            _ = try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script)
            throw Failure(message: "回答期间删除来源后仍然保存了回答")
        } catch let error as LLMError {
            guard case let .serviceError(message) = error else { throw Failure(message: "删除来源后的错误类型不对") }
            try expect(message.contains("删除") || message.contains("更正"), "删除来源后没有作废这次回答")
        }
    }

    private static func cancellationStopsTheRequest() async throws {
        let (storage, store, _) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let script = ScriptedAskModel { _ in
            try await Task.sleep(for: .seconds(30))
            return LLMAnswer(content: #"{"answer":"太慢","citations":[]}"#, citedCaptureIDs: [])
        }
        let task = Task { try await MemoryAssistant(store: store).ask("AtlasScopeToken", model: script) }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do {
            _ = try await task.value
            throw Failure(message: "取消后仍然返回了回答")
        } catch is CancellationError {}
    }

    private static func greetingSkipsRetrieval() async throws {
        let (storage, store, _) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let script = ScriptedAskModel { _ in throw Failure(message: "寒暄不应该调用模型") }
        let answer = try await MemoryAssistant(store: store).ask("hello", model: script)
        let recorded = await script.recorded()
        try expect(recorded.isEmpty, "寒暄调用了模型")
        try expect(answer.citations.isEmpty && !answer.content.contains("AtlasScopeToken"), "寒暄带回了屏幕原文")
    }

    private static func conversationalReplySkipsSearch() async throws {
        let (storage, store, _) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let script = ScriptedAskModel { _ in
            LLMAnswer(content: #"{"reply":"可以告诉我日期或关键词。"}"#, citedCaptureIDs: [])
        }
        let answer = try await MemoryAssistant(store: store).ask("最近怎样", model: script)
        let recorded = await script.recorded()
        try expect(recorded.count == 1 && recorded[0].purpose == .chatPlanning && recorded[0].context.isEmpty, "决定是否查记录之前就把原文放进了上下文")
        try expect(!recorded[0].question.contains("was saved"), "规划请求附上了屏幕原文")
        try expect(answer.citations.isEmpty && answer.content.contains("关键词") && !answer.content.contains("AtlasScopeToken"), "直接回复没有原样返回，或混入了原文")
    }

    private static func statusPrecedesLookup() async throws {
        let (storage, store, capture) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let script = ScriptedAskModel { request in
            if request.purpose == .chatPlanning, !request.question.contains("已读取的工具结果") {
                return LLMAnswer(content: #"{"status":"我先查 AtlasScopeToken。","calls":[{"tool":"search_records","args":{"query":"AtlasScopeToken"}}]}"#, citedCaptureIDs: [])
            }
            return LLMAnswer(content: #"{"answer":"已找到 AtlasScopeToken","citations":[""# + capture.id.uuidString + #""]}"#, citedCaptureIDs: [])
        }
        var status = ""
        let answer = try await MemoryAssistant(store: store).ask("AtlasScopeToken 在哪", onStatus: { status = $0 }, model: script)
        let recorded = await script.recorded()
        // 文档 §4 优化 2：先本地检索，把候选摘录带进第一次规划。隐私边界改为
        // 候选只在问题含关键词时出现、已脱敏、最多 6 条且每条不超过 600 字。
        let firstContext = recorded.first?.context ?? []
        try expect(firstContext.count <= 6, "第一次规划的候选条数超出上限")
        try expect(firstContext.allSatisfy { $0.ocrText.count <= 600 }, "候选摘录没有按上限裁剪")
        try expect(status.contains("AtlasScopeToken"), "查找前没有把进度告诉用户")
        try expect(answer.content.contains("AtlasScopeToken"), "按查询条件检索后没有整理出回答")
        try expect(recorded.contains { $0.purpose == .chatPlanning } && recorded.last?.purpose == .chatPlanning, "查询之后没有给出回答")
    }

    private static func weekOverviewSkipsPlanning() async throws {
        let (storage, store, capture) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let script = ScriptedAskModel { request in
            LLMAnswer(content: "本周记录显示 AtlasScopeToken 已保存 [1]", citedCaptureIDs: [])
        }
        var steps: [String] = []
        let answer = try await MemoryAssistant(store: store).ask("总结本周进展", model: script, onStep: { name, _ in steps.append(name) })
        let purposes = await script.recorded().map(\.purpose)
        try expect(!purposes.contains(.chatPlanning), "总结本周进展仍先走了规划调用")
        try expect(steps.contains("overview-local"), "概览问题没有走本地快速路径")
        try expect(answer.citations == [capture.id] && answer.content.contains("AtlasScopeToken"), "概览回答没有保留本周来源")
        let args = AskAgent.overviewArguments("Atlas 本周进展", now: .now, calendar: .current)
        try expect(args == nil, "带主题的问题被当成纯时间概览")
    }

    private static func reviewEvidenceKeepsOwnText() async throws {
        let (storage, store, capture) = try await fixture("AtlasScopeToken was saved")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let item = DailySummaryItem(section: .progress, title: "保存 Atlas", detail: "AtlasScopeToken", evidenceIDs: [capture.id],
            knowledge: DailyItemKnowledge(topic: "Atlas", kind: .matter, status: "done", ownedByUser: true, quotes: ["AtlasScopeToken was saved"]))
        let summary = DailySummary(day: .now, content: "", sourceCaptureIDs: [capture.id], todos: [], generationKind: .cloud, items: [item])
        try await store.upsertDailySummary(summary)
        let script = ScriptedAskModel { _ in LLMAnswer(content: "本周记录显示 AtlasScopeToken 已保存 [1]", citedCaptureIDs: []) }
        _ = try await MemoryAssistant(store: store).ask("总结本周进展", model: script)
        let answerRequest = await script.recorded().first { $0.purpose == .chat }
        let supplementary = answerRequest?.supplementaryContext ?? ""
        try expect(!supplementary.contains(capture.id.uuidString) || supplementary.contains("每日回顾"), "回顾结果没有按天组织")
        try expect(answerRequest?.context.first?.ocrText.contains("AtlasScopeToken") == true, "回顾来源没有带上自己的原文")
    }

    private static func yesterdayIgnoresPriorAnswerAndToday() async throws {
        let (storage, store, today) = try await fixture("TODAYSCOPE-ONLY")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let midnight = Calendar.current.startOfDay(for: today.createdAt)
        let yesterday = CaptureRecord(eventTemplate: .manualMoment, createdAt: midnight.addingTimeInterval(-3_600),
            sourceAppName: "Yesterday", contentHash: "yesterday-test",
            ocrText: "[聊天·自己] 已核对合成项目的分页边界", textOrigin: .userInput)
        try await store.addCapture(yesterday)
        try await store.addMessage(ConversationMessage(role: .user, content: "我答应了谁什么事？"))
        try await store.addMessage(ConversationMessage(role: .assistant, content: "PRIOR-TURN-ONLY", citations: [today.id]))
        let script = ScriptedAskModel { _ in LLMAnswer(content: "记录显示已核对合成项目的分页边界 [1]", citedCaptureIDs: []) }
        let answer = try await MemoryAssistant(store: store).ask("昨天我做了哪些事情", model: script)
        let requests = await script.recorded()
        try expect(requests.first?.purpose == .chat && !requests.contains { $0.purpose == .chatPlanning }, "昨天概览没有直接读取当天记录")
        try expect(requests.allSatisfy {
            !$0.question.contains("PRIOR-TURN-ONLY") &&
                !($0.supplementaryContext ?? "").contains("TODAYSCOPE-ONLY") &&
                $0.context.allSatisfy { $0.id == yesterday.id }
        }, "昨天概览发送了今天或上一轮的内容")
        try expect(answer.citations == [yesterday.id] && answer.content.contains("分页边界"), "昨天概览没有引用昨天的事项")
        let missing = ScriptedAskModel { _ in LLMAnswer(content: "INVALID-EVIDENCE", citedCaptureIDs: []) }
        let none = try await MemoryAssistant(store: store).ask("前天我做了哪些事情", model: missing)
        let emptyRequests = await missing.recorded()
        try expect(none.citations.isEmpty && emptyRequests.isEmpty, "空白日期调用模型猜测")
    }

    private static func commitmentsRequireUserEvidence() async throws {
        let (storage, store, _) = try await fixture("[聊天·自己] 合成接口文档已交付前端。")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let other = CaptureRecord(eventTemplate: .manualMoment, contentHash: "other-promise",
            ocrText: "[聊天·对方] 我承诺给你发合成凭证。\n[聊天·角色未知] 我答应给你发合成报告。", textOrigin: .screenOCR)
        try await store.addCapture(other)
        let script = ScriptedAskModel { _ in LLMAnswer(content: "INVALID-EVIDENCE", citedCaptureIDs: []) }
        let question = "我答应了谁什么事？"
        let none = try await MemoryAssistant(store: store).ask(question, model: script)
        try expect(none.citations.isEmpty && none.content.contains("承诺"), "交付记录或对方发言被误认为本人承诺")

        let promise = CaptureRecord(eventTemplate: .manualMoment, contentHash: "my-promise",
            ocrText: "[聊天·自己] 如果验收通过，我承诺周五前把合成清单交给林同学。", textOrigin: .screenOCR)
        try await store.addCapture(promise)
        let answer = try await MemoryAssistant(store: store).ask(question, model: script)
        let requests = await script.recorded()
        try expect(answer.citations == [promise.id] && answer.content.contains("林同学") && answer.content.contains("周五前")
                    && answer.content.contains("如果验收通过") && requests.isEmpty, "承诺遗漏原文条件、对象、期限或引用")
    }

    /// 屏幕 OCR 只用来定位：回答模型、核对和兜底都只看到每日回顾的事项，回答引用回到事项的来源记录。
    private static func screenTextNeverReachesTheAnswer() async throws {
        let (storage, store, _) = try await fixture("placeholder")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let day = Calendar.current.date(byAdding: .day, value: -2, to: Calendar.current.startOfDay(for: .now))!.addingTimeInterval(3_600)
        let shot = CaptureRecord(eventTemplate: .enterKeyTrigger, createdAt: day, sourceAppName: "终端", contentHash: "ocr-shot",
            ocrText: "RAWOCR-NOISE 编辑 查看 窗口 口 biz-x-srv dev_1 #216 merged", textOrigin: .screenOCR)
        let admin = CaptureRecord(eventTemplate: .enterKeyTrigger, createdAt: day.addingTimeInterval(60), sourceAppName: "浏览器", contentHash: "ocr-admin",
            ocrText: "RAWOCR-ADMIN sessions feedback 运营后台", textOrigin: .screenOCR)
        try await store.addCapture(shot)
        try await store.addCapture(admin)
        let release = DailySummaryItem(section: .progress, title: "一键发版合并并部署生产，功能开关仍关闭", detail: "#216 已合并",
            evidenceIDs: [shot.id], knowledge: DailyItemKnowledge(topic: "一键发版", kind: .matter, status: "inProgress", ownedByUser: true, quotes: ["#216 merged"]))
        let review = DailySummary(day: day, content: "", sourceCaptureIDs: [shot.id, admin.id], todos: [], generationKind: .cloud, items: [release])
        try await store.upsertDailySummary(review)
        let script = ScriptedAskModel { request in
            LLMAnswer(content: "前天主要推进了一键发版。[1]\n\n- #216 已合并，功能开关仍关闭 [1]", citedCaptureIDs: [])
        }
        let answer = try await MemoryAssistant(store: store).ask("前天我做了什么", model: script)
        let sent = await script.recorded().map { $0.question + ($0.supplementaryContext ?? "") + $0.context.map(\.ocrText).joined() }.joined()
        try expect(!sent.contains("RAWOCR"), "屏幕原文被发给了模型")
        try expect(sent.contains("一键发版合并并部署生产"), "每日回顾事项没有作为材料")
        try expect(answer.content.contains("#216 已合并") && answer.content.contains("- ") && answer.citations == [shot.id], "回答被改写，或引用没有回到事项的来源记录")
        try expect(!answer.content.contains("RAWOCR") && !answer.content.contains("已省略"), "回答混入了原文或套话")
    }

    /// 没有每日回顾、也没有已整理内容的日期：不调用模型，提示先生成回顾。
    private static func dayWithoutReviewAsksToGenerate() async throws {
        let (storage, store, _) = try await fixture("placeholder")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now))!.addingTimeInterval(3_600)
        try await store.addCapture(CaptureRecord(eventTemplate: .enterKeyTrigger, createdAt: day, sourceAppName: "终端", contentHash: "ocr-only",
            ocrText: "RAWOCR-ONLY 编辑 查看 窗口", textOrigin: .screenOCR))
        let script = ScriptedAskModel { _ in LLMAnswer(content: "INVALID", citedCaptureIDs: []) }
        let answer = try await MemoryAssistant(store: store).ask("昨天我做了什么", model: script)
        let requests = await script.recorded()
        try expect(requests.isEmpty, "只有原始截图的日期仍调用了模型")
        try expect(answer.content.contains("还没有每日回顾") && !answer.content.contains("RAWOCR") && answer.citations.isEmpty, "没有提示先生成回顾，或展示了原文")
    }

    private static func recentSpanTopicAndCategorySynthesis() async throws {
        let q1 = "你梳理下atlas 最近一周有什么进展"
        try expect(QuestionTerms.topicTerms(q1).contains("atlas") && QuestionTerms.termLookup(QuestionTerms.topicTerms(q1)).words.contains("atlas"), "中英文紧邻时丢失了英文主题词")
        let q2 = "最近一周我学了哪些管理知识"
        let q2Lookup = QuestionTerms.termLookup(QuestionTerms.topicTerms(q2))
        try expect(!q2Lookup.groups.joined().contains("一周") && !q2Lookup.groups.joined().contains("些管"), "时间词和疑问词残片混入了词条检索组：\(q2Lookup)")

        let (storage, store, placeholder) = try await fixture("placeholder")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        _ = try await store.deleteCapture(id: placeholder.id)
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let d4 = cal.date(byAdding: .day, value: -4, to: today)!.addingTimeInterval(3_600)
        let d2 = cal.date(byAdding: .day, value: -2, to: today)!.addingTimeInterval(3_600)
        let d1 = cal.date(byAdding: .day, value: -1, to: today)!.addingTimeInterval(3_600)

        let capFlomo = CaptureRecord(eventTemplate: .enterKeyTrigger, createdAt: d4, sourceAppName: "合成笔记A", contentHash: "c-flomo",
            ocrText: "RAWOCR-FLOMO 小团队激励机制：能力成长与责任扩大", textOrigin: .screenOCR)
        let capWiz = CaptureRecord(eventTemplate: .enterKeyTrigger, createdAt: d4.addingTimeInterval(60), sourceAppName: "合成笔记B", contentHash: "c-wiz",
            ocrText: "RAWOCR-WIZ 端到端组织变革研究：分工与能力网络", textOrigin: .screenOCR)
        let capAtlasRef = CaptureRecord(eventTemplate: .enterKeyTrigger, createdAt: d2, sourceAppName: "合成终端", contentHash: "c-atlas-ref",
            ocrText: "RAWOCR-ATLAS2 Atlas 记忆侧栏修复已合入", textOrigin: .screenOCR)
        let capAtlasMain = CaptureRecord(eventTemplate: .enterKeyTrigger, createdAt: d1, sourceAppName: "合成编辑器", contentHash: "c-atlas-main",
            ocrText: "RAWOCR-ATLAS1 Atlas 问答修复已进入主分支", textOrigin: .screenOCR)
        let capAtlasUncovered = CaptureRecord(eventTemplate: .enterKeyTrigger, createdAt: d1.addingTimeInterval(30), sourceAppName: "合成编辑器", contentHash: "c-atlas-menu",
            ocrText: "RAWOCR-MENU Atlas 菜单栏界面", textOrigin: .screenOCR)
        for c in [capFlomo, capWiz, capAtlasRef, capAtlasMain, capAtlasUncovered] { try await store.addCapture(c) }

        var rev4 = DailySummary(day: d4, content: "", sourceCaptureIDs: [capFlomo.id, capWiz.id], todos: [], generationKind: .cloud, items: [
            DailySummaryItem(section: .progress, title: "整理小团队激励与管理决策框架", detail: "区分决定与决策并形成四个激励支点", evidenceIDs: [capFlomo.id],
                knowledge: DailyItemKnowledge(topic: "小团队激励与管理决策", kind: .matter, status: "completed", ownedByUser: true, quotes: ["小团队激励机制"]))
        ])
        rev4.ledger = [
            DailyMatterLedgerEntry(topic: "端到端组织变革", kind: .reference, status: "completed", section: "insights",
                title: "保存并研读端到端组织变革研究", detail: "涉及分工终结与能力网络演进", ownedByUser: true, quotes: [], evidenceIDs: [capWiz.id], occurredAt: nil)
        ]
        var rev2 = DailySummary(day: d2, content: "", sourceCaptureIDs: [capAtlasRef.id], todos: [], generationKind: .cloud, items: [])
        rev2.ledger = [
            DailyMatterLedgerEntry(topic: "Atlas侧栏修复", kind: .reference, status: "completed", section: "progress",
                title: "Atlas记忆侧栏修复已合入本地构建", detail: "修复菜单挤压并通过构建验证", ownedByUser: true, quotes: [], evidenceIDs: [capAtlasRef.id], occurredAt: nil)
        ]
        let rev1 = DailySummary(day: d1, content: "", sourceCaptureIDs: [capAtlasMain.id, capAtlasUncovered.id], todos: [], generationKind: .cloud, items: [
            DailySummaryItem(section: .progress, title: "Atlas问答修复已进入主分支", detail: "完成本地构建与验证", evidenceIDs: [capAtlasMain.id],
                knowledge: DailyItemKnowledge(topic: "Atlas问答优化", kind: .matter, status: "inProgress", ownedByUser: true, quotes: ["Atlas 问答修复"]))
        ])
        for r in [rev4, rev2, rev1] { try await store.upsertDailySummary(r) }

        let atlasModel = ScriptedAskModel { request in
            let i1 = (request.context.firstIndex { $0.ocrText.contains("Atlas问答修复") } ?? 0) + 1
            let i2 = (request.context.firstIndex { $0.ocrText.contains("Atlas记忆侧栏") } ?? 0) + 1
            return LLMAnswer(content: "Atlas 最近一周推进了两项修复。\n\n- 问答修复进入主分支（进行中） [\(i1)]\n- 记忆侧栏修复已合入本地构建 [\(i2)]", citedCaptureIDs: [])
        }
        let a1 = try await MemoryAssistant(store: store).ask(q1, model: atlasModel)
        let atlasSent = await atlasModel.recorded().flatMap(\.context).map(\.ocrText).joined(separator: "\n")
        try expect(atlasSent.contains("Atlas问答修复已进入主分支") && atlasSent.contains("Atlas记忆侧栏修复已合入本地构建"), "最近一周主题梳理漏掉了回顾或参考账本条目：\(atlasSent)")
        try expect(!atlasSent.contains("RAWOCR"), "屏幕原始 OCR 被发给了回答模型")
        try expect(Set(a1.citations) == Set([capAtlasMain.id, capAtlasRef.id]), "引用未完整对应到两条 Atlas 来源：\(a1.citations)")
        try expect((a1.missingReviewDays ?? []).isEmpty, "已有每日回顾的日期被误报为缺少回顾：\(String(describing: a1.missingReviewDays))")

        let mgmtModel = ScriptedAskModel { request in
            let m1 = (request.context.firstIndex { $0.ocrText.contains("小团队激励") } ?? 0) + 1
            let m2 = (request.context.firstIndex { $0.ocrText.contains("组织变革") } ?? 0) + 1
            return LLMAnswer(content: "最近一周记录了两项管理与组织相关内容。\n\n1. 整理了小团队激励与管理决策框架 [\(m1)]\n2. 研读了端到端组织变革与能力网络研究 [\(m2)]", citedCaptureIDs: [])
        }
        let a2 = try await MemoryAssistant(store: store).ask(q2, model: mgmtModel)
        let mgmtSent = await mgmtModel.recorded().flatMap(\.context).map(\.ocrText).joined(separator: "\n")
        try expect(mgmtSent.contains("整理小团队激励与管理决策框架") && mgmtSent.contains("保存并研读端到端组织变革研究"), "最近一周管理知识提问漏掉了管理框架或组织变革笔记：\(mgmtSent)")
        try expect(Set(a2.citations) == Set([capFlomo.id, capWiz.id]) && !a2.content.contains("没有找到可用的记录"), "管理知识提问未能整合多条来源：\(a2.content)")
    }

    private static func topicScopeKeepsDailyReviewItems() async throws {
        let (storage, store, placeholder) = try await fixture("placeholder")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        _ = try await store.deleteCapture(id: placeholder.id)
        let d1 = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now))!.addingTimeInterval(3_600)
        let topicCap = CaptureRecord(eventTemplate: .enterKeyTrigger, createdAt: d1, sourceAppName: "合成终端", sourceBundleIdentifier: "example.allowed",
            contentHash: "topic-cap", ocrText: "RAWOCR-TOPIC Nova 分页校验通过", textOrigin: .screenOCR)
        let otherCap = CaptureRecord(eventTemplate: .enterKeyTrigger, createdAt: d1.addingTimeInterval(60), sourceAppName: "合成私密", sourceBundleIdentifier: "example.excluded",
            contentHash: "other-cap", ocrText: "RAWOCR-SECRET 私密无关事项", textOrigin: .screenOCR)
        try await store.addCapture(topicCap)
        try await store.addCapture(otherCap)
        var privacy = await store.snapshot().privacy
        privacy.excludedBundleIdentifiers.insert("example.excluded")
        try await store.updatePrivacy(privacy)
        let review = DailySummary(day: d1, content: "", sourceCaptureIDs: [topicCap.id, otherCap.id], todos: [], generationKind: .cloud, items: [
            DailySummaryItem(section: .progress, title: "Nova分页校验已在本地通过", detail: "分页边界用例通过", evidenceIDs: [topicCap.id],
                knowledge: DailyItemKnowledge(topic: "Nova分页", kind: .matter, status: "inProgress", ownedByUser: true, quotes: ["Nova 分页校验"])),
            DailySummaryItem(section: .progress, title: "EXCLUDED-ITEM-LEAK", detail: "私密条目", evidenceIDs: [otherCap.id],
                knowledge: DailyItemKnowledge(topic: "私密", kind: .matter, status: "inProgress", ownedByUser: true, quotes: ["私密"]))
        ])
        try await store.upsertDailySummary(review)
        let script = ScriptedAskModel { request in
            if request.purpose == .chatPlanning {
                return LLMAnswer(content: #"{"answer":"Nova分页校验已在本地通过 [1]"}"#, citedCaptureIDs: [])
            }
            return LLMAnswer(content: "Nova分页校验已在本地通过 [1]", citedCaptureIDs: [])
        }
        let scope = MemoryQueryScope(topicID: "topic-nova", topicEvidenceIDs: [topicCap.id])
        let answer = try await MemoryAssistant(store: store).ask("Nova 进展怎样", scope: scope, model: script)
        let sent = await script.recorded().flatMap(\.context).map(\.ocrText).joined(separator: "\n")
        try expect(!sent.contains("EXCLUDED-ITEM-LEAK") && !sent.contains("RAWOCR"), "被排除应用的条目或原始 OCR 泄露进了模型上下文")
        try expect(answer.citations == [topicCap.id] && answer.content.contains("Nova分页校验"), "按主题筛选或同日存在排除应用时误丢了该主题的每日回顾事项：\(answer.content)")
    }

    private static func plannerFormattingAndGroundingResilience() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let sunday = cal.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 10))! // Sunday
        let (storage, store, placeholder) = try await fixture("placeholder")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        _ = try await store.deleteCapture(id: placeholder.id)
        let cap = CaptureRecord(eventTemplate: .manualMoment, createdAt: sunday, sourceAppName: "合成笔记", contentHash: "sun-cap",
            ocrText: "整理并记录小团队激励与管理决策框架", textOrigin: .userInput)
        try await store.addCapture(cap)
        let script = ScriptedAskModel { request in
            if request.purpose == .chatPlanning {
                return LLMAnswer(content: "<think>先核对{候选}材料</think>\n{\"answer\":\"研究资料沉淀\n1. 11月22日整理并记录了小团队激励与管理决策框架。[1]\"}", citedCaptureIDs: [])
            }
            return LLMAnswer(content: "不应走到回退", citedCaptureIDs: [])
        }
        let answer = try await MemoryAssistant(store: store).ask("激励与管理决策", model: script)
        try expect(answer.citations == [cap.id] && answer.content.contains("11月22日整理并记录了") && !answer.content.contains("没能整理成完整回答"),
            "含 <think>、原始换行、编号列表与记录日期的回答被误判失败：\(answer.content)")
        let blocks = ChatResponseFormatter().attributedParagraphs("研究资料沉淀\n- 已在知笔记保存阅读材料。[1]\n- 涉及三个变化方向。[1]")
        let plain = blocks.map { String($0.characters) }.joined(separator: "\n\n")
        try expect(!plain.contains("研究资料沉淀已在知笔记") && plain.contains("\n"), "Markdown 段落渲染把小标题与列表粘连成了一行：\(plain)")
    }

    private static func middaySummaryRefreshesTodayAutomatically() async throws {
        let cal = Calendar.current
        let now = Date.now
        let todayStart = cal.startOfDay(for: now)
        guard now.timeIntervalSince(todayStart) > 5 else { return }
        let (storage, store, placeholder) = try await fixture("placeholder")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        _ = try await store.deleteCapture(id: placeholder.id)

        let yesterday = todayStart.addingTimeInterval(-3_600)
        let yCap = CaptureRecord(eventTemplate: .enterKeyTrigger, createdAt: yesterday, sourceAppName: "合成终端", contentHash: "y-cap",
            ocrText: "RAWOCR-YESTERDAY 昨日完成数据库索引核对", textOrigin: .screenOCR)
        let morningTime = todayStart.addingTimeInterval(max(1, (now.timeIntervalSince(todayStart) * 0.2)))
        let afternoonTime = todayStart.addingTimeInterval(max(2, (now.timeIntervalSince(todayStart) * 0.6)))
        let morningCap = CaptureRecord(eventTemplate: .enterKeyTrigger, createdAt: morningTime, sourceAppName: "合成编辑器", contentHash: "m-cap",
            ocrText: "[聊天·自己] 上午完成网关配置初稿。", textOrigin: .screenOCR)
        let afternoonCap = CaptureRecord(eventTemplate: .enterKeyTrigger, createdAt: afternoonTime, sourceAppName: "合成终端", contentHash: "a-cap",
            ocrText: "[聊天·自己] 下午两点完成网关切换压测。", textOrigin: .screenOCR)
        for c in [yCap, morningCap, afternoonCap] { try await store.addCapture(c) }

        let ySummary = DailySummary(day: yesterday, content: "", sourceCaptureIDs: [yCap.id], todos: [], generationKind: .cloud, items: [
            DailySummaryItem(section: .progress, title: "完成数据库索引核对", detail: "昨日完成索引核对", evidenceIDs: [yCap.id],
                knowledge: DailyItemKnowledge(topic: "数据库索引", kind: .matter, status: "completed", ownedByUser: true, quotes: ["数据库索引核对"]))
        ])
        let mSummary = DailySummary(day: todayStart, content: "", sourceCaptureIDs: [morningCap.id], todos: [], generationKind: .cloud, items: [
            DailySummaryItem(section: .progress, title: "上午完成网关配置初稿", detail: "网关配置初稿已保存", evidenceIDs: [morningCap.id],
                knowledge: DailyItemKnowledge(topic: "网关切换", kind: .matter, status: "inProgress", ownedByUser: true, quotes: ["上午完成网关配置初稿。"]))
        ])
        try await store.upsertDailySummary(ySummary)
        try await store.upsertDailySummary(mSummary)

        let model = ScriptedAskModel { request in
            if request.purpose == .reviewSynthesis {
                let items: [[String: Any]] = [
                    ["section": "progress", "title": "网关配置与下午切换压测已完成", "detail": "上午完成网关配置初稿，下午两点完成网关切换压测。",
                     "owner": "user", "status": "completed", "explicitCommitment": false, "condition": NSNull(),
                     "evidence": [["id": "d1", "quote": "[聊天·自己] 上午完成网关配置初稿。"], ["id": "d2", "quote": "[聊天·自己] 下午两点完成网关切换压测。"]]]
                ]
                let draft = json(["overview": "今天完成网关配置与压测。", "items": items,
                                  "coverage": [["id": "d1", "disposition": "used"], ["id": "d2", "disposition": "used"]]])
                return LLMAnswer(content: draft, citedCaptureIDs: [])
            }
            let i1 = (request.context.firstIndex { $0.ocrText.contains("数据库索引核对") } ?? 0) + 1
            let i2 = (request.context.firstIndex { $0.ocrText.contains("下午切换压测") } ?? 0) + 1
            return LLMAnswer(content: "本周推进了两项工作。\n\n- 完成数据库索引核对 [\(i1)]\n- 完成网关配置与下午切换压测 [\(i2)]", citedCaptureIDs: [])
        }

        var statuses: [String] = []
        var steps: [String] = []
        let firstAnswer = try await MemoryAssistant(store: store).ask("总结最近3天进展", onStatus: { statuses.append($0) }, model: model, onStep: { name, _ in steps.append(name) })
        try expect(statuses.contains { $0.contains("正在整理今日最新记录") }, "下午提问未展示整理今日记录进度：\(statuses)")
        try expect(steps.contains("today-review"), "下午提问未自动刷新今日回顾：\(steps)")
        try expect(Set(firstAnswer.citations).isSuperset(of: [yCap.id, afternoonCap.id]), "总结近期进展漏掉了今天下午刚产生的记录：\(firstAnswer.citations)")
        try expect((firstAnswer.missingReviewDays ?? []).isEmpty, "今日已自动整理却仍提示缺少回顾：\(String(describing: firstAnswer.missingReviewDays))")
        let savedToday = await store.snapshot().dailyReview(on: todayStart)
        try expect(savedToday?.sourceCaptureIDs.contains(afternoonCap.id) == true && !(savedToday?.versions ?? []).isEmpty, "自动刷新今日回顾后未保存新来源或未保留上午旧版本")

        // Asking again with no new captures must NOT trigger another daily review synthesis call.
        var secondSteps: [String] = []
        _ = try await MemoryAssistant(store: store).ask("总结最近3天进展", model: model, onStep: { name, _ in secondSteps.append(name) })
        try expect(!secondSteps.contains("today-review"), "今日无新增记录时重复触发了每日回顾生成：\(secondSteps)")
    }

    private static func scopedMultiTurnMetaFollowUpAndDeduplication() async throws {
        let (storage, store, placeholder) = try await fixture("placeholder")
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        _ = try await store.deleteCapture(id: placeholder.id)
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now))!.addingTimeInterval(3_600)
        let cap = CaptureRecord(
            eventTemplate: .enterKeyTrigger,
            createdAt: day,
            sourceAppName: "合成编辑器",
            sourceBundleIdentifier: "example.allowed",
            contentHash: "nova-cleanup-pr",
            ocrText: "RAWOCR-NOVA PR #210 merged, production still old",
            textOrigin: .screenOCR
        )
        try await store.addCapture(cap)
        let review = DailySummary(day: day, content: "", sourceCaptureIDs: [cap.id], todos: [], generationKind: .cloud, items: [
            DailySummaryItem(
                section: .progress,
                title: "Nova入口移除已合入 main，但线上仍是旧版本",
                detail: "相关改动已完成并通过 PR #210 合入 main，当前尚未部署生产环境。",
                evidenceIDs: [cap.id],
                knowledge: DailyItemKnowledge(topic: "Nova入口移除", kind: .matter, status: "inProgress", ownedByUser: true, quotes: ["PR #210 merged"])
            )
        ])
        try await store.upsertDailySummary(review)
        _ = try await store.organizeMemoryInBackground(force: true)

        let topicID = "topic:nova-cleanup"
        try await store.activateSession(topicID: topicID)
        let scope = MemoryQueryScope(topicID: topicID, topicEvidenceIDs: [cap.id])

        let turn1Model = ScriptedAskModel { request in
            if request.purpose == .chatPlanning, !request.question.contains("已读取的工具结果") {
                return LLMAnswer(content: #"{"calls":[{"tool":"get_topic","args":{"name":"Nova入口移除"}}]}"#, citedCaptureIDs: [])
            }
            return LLMAnswer(content: #"{"answer":"Nova入口移除改动已完成并合入 main（PR #210），但当前尚未部署生产环境。[1]"}"#, citedCaptureIDs: [])
        }
        let turn1 = try await MemoryAssistant(store: store).ask("梳理一下“Nova入口移除”最近的进展和当前状态。", scope: scope, model: turn1Model)
        let turn1Contexts = await turn1Model.recorded().last?.context ?? []
        try expect(turn1Contexts.count == 1, "同源的每日回顾事项与主题知识条目未去重，重复送入了上下文：\(turn1Contexts.map(\.ocrText))")
        try expect(!turn1.content.contains("没能整理成完整回答") && turn1.citations == [cap.id],
                   "带明确未部署限定条件的子步骤已完成表述被核验误杀：\(turn1.content)")

        let turn2Model = ScriptedAskModel { request in
            LLMAnswer(
                content: "<think>用户觉得上一条太绕，用大白话讲清楚</think>我刚才主要汇报了共 2 点情况：\n- 代码改动已完成并合入 main（PR #210）\n- 但目前尚未部署到生产环境，线上仍是旧版本",
                citedCaptureIDs: []
            )
        }
        let turn2 = try await MemoryAssistant(store: store).ask("你这个都回复了什么啊", scope: scope, model: turn2Model)
        let turn2Recorded = await turn2Model.recorded()
        try expect(turn2Recorded.first?.purpose == .chat && turn2Recorded.first?.question.contains("此前对话") == true,
                   "限定主题范围下追问丢失了上一轮会话上下文：\(turn2Recorded.map(\.purpose))")
        try expect(!turn2.content.contains("<think>") && !turn2.content.contains("没能整理成完整回答") && turn2.content.contains("尚未部署"),
                   "追问澄清回复未剥离 <think> 或因无显式 [1] 标记跌入兜底：\(turn2.content)")
        try expect(turn2.citations == [cap.id], "追问澄清回复丢失了上一轮继承的可追溯来源：\(turn2.citations)")
    }

    static func fixture(_ text: String) async throws -> (RecallStorage, FileMemoryStore, CaptureRecord) {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-ask-agent-" + UUID().uuidString))
        let store = try verificationStore(storage: storage)
        let capture = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "合成验证", sourceBundleIdentifier: "example.ask-agent",
            contentHash: UUID().uuidString, ocrText: text, textOrigin: .userInput)
        try await store.addCapture(capture)
        var privacy = await store.snapshot().privacy
        privacy.cloudUseEnabled = true
        try await store.updatePrivacy(privacy)
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .openAICompatible, baseURLString: "https://example.test/v1", model: "test", apiKey: "test-key"))
        return (storage, store, capture)
    }

}

func json(_ object: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

actor ScriptedAskModel: LLMResponding {
    private let handler: @Sendable (LLMRequest) async throws -> LLMAnswer
    private var stored: [LLMRequest] = []
    init(_ handler: @escaping @Sendable (LLMRequest) async throws -> LLMAnswer) { self.handler = handler }
    func answer(to request: LLMRequest) async throws -> LLMAnswer {
        stored.append(request)
        if request.purpose == .answerVerification {
            return LLMAnswer(content: #"{"unsupported":[]}"#, citedCaptureIDs: [])
        }
        return try await handler(request)
    }
    func recorded() -> [LLMRequest] { stored }
}
