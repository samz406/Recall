import Foundation
import RecallKit

/// End-to-end pipeline contracts with fabricated evidence and deterministic model responses.
/// These verify coverage, cancellation and provenance, not production model accuracy.
enum ModelReviewVerification {
    struct Failure: LocalizedError { var message: String; var errorDescription: String? { message } }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    actor Model: LLMResponding {
        var requests: [LLMRequest] = []
        var mode: String
        var pages = 0
        init(_ mode: String = "valid") { self.mode = mode }
        func reset(_ value: String) { mode = value }
        func log() -> [LLMRequest] { requests }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            requests.append(request)
            let input = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
            let object: [String: Any]
            switch request.purpose {
            case .captureUnderstanding:
                pages += 1
                if mode == "cancel-second", pages == 2 { throw CancellationError() }
                let primary = input.filter { $0["contextOnly"] as? Bool != true }
                var facts: [[String: Any]] = []
                if mode != "empty" {
                    for (index, block) in primary.enumerated() {
                        let raw = block["text"] as! String
                        let promise = raw.contains("我会")
                        facts.append(["id": "f\(index)", "subject": "Atlas 分页边界验证",
                            "detail": String(raw.replacingOccurrences(of: "[聊天·自己] ", with: "").prefix(180)),
                            "kind": promise ? "commitment" : "event", "speaker": "user", "actor": "user",
                            "status": promise ? "pending" : "completed", "condition": NSNull(),
                            "messageTime": NSNull(), "eventTime": NSNull(), "deadline": NSNull(),
                            "evidence": [["blockID": block["id"]!, "quote": raw]]])
                    }
                }
                object = ["facts": facts, "coverage": primary.map { ["blockID": $0["id"]!, "disposition": mode == "empty" ? "noise" : "fact"] }]
            case .captureUnderstandingAudit:
                let text = request.question.components(separatedBy: "草稿（数据）：\n").last!
                let draft = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
                let facts = draft["facts"] as! [[String: Any]]
                object = ["acceptedFactIDs": facts.map { $0["id"]! }, "checkedBlockIDs": input.filter { $0["contextOnly"] as? Bool != true }.map { $0["id"]! }, "missedBlockIDs": []]
            case .reviewSynthesis:
                if mode == "malformed" { return LLMAnswer(content: "{broken-json", citedCaptureIDs: []) }
                let node = input.last!
                let data = try JSONSerialization.jsonObject(with: Data((node["detail"] as! String).utf8)) as! [String: Any]
                let meta = (data["facts"] as? [[String: Any]])?.first ?? data
                let facts = node["factIDs"] as! [String]
                let action = mode == "invent-action" || meta["isAction"] as? Bool == true
                let title = action ? "修缮 Atlas 分页异常用例" : "Atlas 分页边界验证完成"
                let detail = action ? "补齐空页与跨页数据后提交评审。" : "分页边界和空值用例通过，原始记录中的完成状态得到保留。"
                let item: [String: Any] = ["section": action ? "actions" : "progress", "title": title, "detail": detail, "factIDs": Array(facts.prefix(12))]
                object = ["overview": request.question.contains("这是最终回顾") ? "本期推进了 Atlas 分页边界验证。" : "", "items": [item],
                    "coverage": input.map { entry in ["nodeID": entry["id"]!, "disposition": (entry["id"] as! String) == (node["id"] as! String) ? "used" : "background"] }]
            case .reviewAudit:
                let reject = mode == "reject-audit" || (mode == "reject-original" && request.question.contains("核对最终条目"))
                object = ["supported": !reject, "attribution": true, "stateAndTime": true, "useful": true, "complete": true,
                    "checkedNodeIDs": input.map { $0["id"]! }]
            default: throw Failure(message: "正式回顾误用了旧的摘要请求：\(request.purpose)")
            }
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    struct Fixture {
        var storage: RecallStorage
        var store: FileMemoryStore
        var period: ReviewPeriod
        var records: [CaptureRecord]
    }
    static func fixture(count: Int = 1, raw: Bool = false, text: String? = nil) async throws -> Fixture {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-model-review-" + UUID().uuidString))
        let store = try FileMemoryStore(storage: storage)
        let now = Date.now
        var records: [CaptureRecord] = []
        for i in 0..<count {
            let date = now.addingTimeInterval(-Double(count - i) * 3)
            let detail = "Atlas 分页第 \(i) 组已完成边界与空值验证，检查结论已保存。"
            let source = CaptureRecord(eventTemplate: .workCheckpoint, createdAt: date, sourceAppName: "合成测试",
                sourceBundleIdentifier: "example.synthetic-review", contentHash: UUID().uuidString,
                ocrText: text ?? "[聊天·自己] \(detail)", textOrigin: .userInput,
                manualMatter: raw ? nil : ManualMatterNote(title: "Atlas 分页第 \(i) 组验证", detail: detail, status: .completed, eventAt: date))
            try await store.addCapture(source); records.append(source)
        }
        try await store.updatePrivacy(PrivacySettings(cloudUseEnabled: true))
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .openAICompatible, model: "synthetic", apiKey: "verification-placeholder"))
        return Fixture(storage: storage, store: store, period: ReviewPeriod(start: now.addingTimeInterval(-Double(count) * 4 - 10), end: now), records: records)
    }
    static func generate(_ f: Fixture, model: Model) async throws -> ModelReviewResult {
        let prepared = try await f.store.prepareModelReview(period: f.period, responder: model)
        return try await ModelReviewEngine().generate(in: prepared, period: f.period,
            beforeCall: { try await f.store.validateModelReview(prepared, period: f.period) }, responder: model)
    }
    static func run() async throws {
        try await fullRangeAndReuse()
        try await longRecordAndResume()
        try await hierarchyAndNoSampling()
        try await actionsFromMeaning()
        try await noLocalFallback()
        try await independentOriginalAudit()
        try await privacyBetweenCalls()
        try await changedSources()
        try await emptyUnderstanding()
        try await discardedUnderstanding()
        try await persistenceAndDeletion()
        try migrationAndSchedule()
        print("PASS: 12 model-first review scenarios (full range, model-only narratives, audit, reuse, resume, privacy and deletion)")
    }
    static func fullRangeAndReuse() async throws {
        let f = try await fixture(count: 40, raw: true); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Model()
        let result = try await generate(f, model: model)
        try expect(result.coverage.sourceCount == 40 && result.coverage.factCount == 40, "正式回顾仍在使用 36 条采样或遗漏记录")
        let before = await model.log().filter { $0.purpose == .captureUnderstanding }.count
        _ = try await generate(f, model: model)
        let after = await model.log().filter { $0.purpose == .captureUnderstanding }.count
        try expect(before == 40 && after == before, "已有模型理解结果被重复调用，或未逐条补齐")
        let state = await f.store.snapshot()
        try expect(!state.understandingSettings.enabled, "手动生成偷偷打开了后台自动处理开关")
    }
    static func longRecordAndResume() async throws {
        let text = (0..<55).map { "[聊天·自己] Atlas 第 \($0) 个分页测试已完成，包含空值和边界验证。" }.joined(separator: "\n") + "\n[聊天·自己] Atlas 文末尾部用例已完成。"
        let f = try await fixture(raw: true, text: text); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Model("cancel-second")
        do { _ = try await generate(f, model: model); throw Failure(message: "取消未生效") } catch is CancellationError { }
        let paused = await f.store.snapshot()
        try expect(paused.understandingJobs.first?.nextPage == 1, "取消后丢失已保存的分页理解进度")
        await model.reset("valid")
        _ = try await generate(f, model: model)
        let log = await model.log().filter { $0.purpose == .captureUnderstanding }
        try expect(log.contains { $0.context[0].ocrText.contains("文末尾部用例") }, "长记录尾部仍被截掉")
        try expect(log.count == 4, "恢复没有从分页检查点继续")
    }
    static func hierarchyAndNoSampling() async throws {
        let f = try await fixture(count: 73); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Model(); let result = try await generate(f, model: model)
        let log = await model.log().filter { $0.purpose == .reviewSynthesis }
        var seen: Set<String> = []
        for request in log {
            let nodes = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
            for node in nodes { if let id = node["id"] as? String, result.facts.contains(where: { $0.id == id }) { seen.insert(id) } }
        }
        try expect(result.coverage.factCount == 73 && seen.count == 73 && log.count > 1, "分层综合没有覆盖全部事实")
    }
    static func actionsFromMeaning() async throws {
        let f = try await fixture(raw: true, text: "[聊天·自己] 我会修缮 Atlas 分页异常用例并提交评审。")
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let result = try await generate(f, model: Model())
        let report = result.dailySummary(day: f.records[0].createdAt)
        try expect(report.todos.count == 1 && report.items.contains { $0.section == .actions }, "模型明确识别的行动仍被本地候选词表否决")
        let copy = try JSONDecoder().decode(DailySummary.self, from: JSONEncoder().encode(report))
        try expect(copy.todos.count == 1 && copy.items == report.items, "持久化后又退回旧的行动关键词过滤")
    }
    static func noLocalFallback() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Model(); let initial = try await generate(f, model: model)
        let prepared = await f.store.snapshot(); let old = initial.dailySummary(day: f.records[0].createdAt)
        try await f.store.commitModelDailySummary(old, expected: prepared, period: f.period)
        await model.reset("malformed")
        do { _ = try await generate(f, model: model); throw Failure(message: "坏 JSON 被当作正式回顾") } catch is ModelReviewError { }
        let current = await f.store.snapshot()
        try expect(current.dailySummaries.contains { $0.id == old.id && $0.content == old.content }, "模型失败替换或清空了原回顾")
        await model.reset("invent-action")
        do { _ = try await generate(f, model: model); throw Failure(message: "已完成事项被编造为待办") } catch is ModelReviewError { }
    }
    static func independentOriginalAudit() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        do { _ = try await generate(f, model: Model("reject-original")); throw Failure(message: "只审核了中间摘要，没有核验原始结构化事实") } catch is ModelReviewError { }
    }
    static func privacyBetweenCalls() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let state = await f.store.snapshot(); let model = Model()
        let counter = Gate()
        do {
            _ = try await ModelReviewEngine().generate(in: state, period: f.period, beforeCall: {
                if await counter.next() == 2 { try await f.store.updatePrivacy(PrivacySettings(cloudUseEnabled: false)) }
                try await f.store.validateModelReview(state, period: f.period)
            }, responder: model)
            throw Failure(message: "关闭云端后仍继续审核调用")
        } catch is WeeklyReviewError { }
        let log = await model.log(); try expect(log.count == 1, "关闭云端后又发出了模型请求")
    }
    actor Gate { var count = 0; func next() -> Int { count += 1; return count } }
    static func changedSources() async throws {
        let f = try await fixture(raw: true); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let prepared = try await f.store.prepareModelReview(period: f.period, responder: Model())
        try await f.store.correctCaptureText(f.records[0].id, text: "[聊天·自己] Atlas 验证尚未完成。")
        do { try await f.store.validateModelReview(prepared, period: f.period); throw Failure(message: "更正后仍使用旧结果") } catch is WeeklyReviewError { }
    }
    static func emptyUnderstanding() async throws {
        let f = try await fixture(raw: true); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        do { _ = try await generate(f, model: Model("empty")); throw Failure(message: "零条理解结果重新唤醒了 OCR 关键词待办") } catch is WeeklyReviewError { }
    }
    static func discardedUnderstanding() async throws {
        let f = try await fixture(raw: true); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        try await f.store.removeCaptureUnderstanding(f.records[0].id)
        let model = Model()
        do { _ = try await generate(f, model: model); throw Failure(message: "用户停用的理解被自动恢复") } catch is ModelReviewError { }
        let log = await model.log(); try expect(log.isEmpty, "停用记录仍被外发")
    }
    static func persistenceAndDeletion() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let result = try await generate(f, model: Model()); let state = await f.store.snapshot()
        let topic = TopicModelReview(topicID: "synthetic-topic", result: result)
        try await f.store.commitTopicReview(topic)
        let template = ReviewTemplate(kind: .personal)
        let weekly = result.weeklyReport(period: f.period, template: template, scope: ReviewScope(), in: state)
        _ = try await f.store.commitWeeklyReport(weekly)
        let reopened = try FileMemoryStore(storage: f.storage); let saved = await reopened.snapshot()
        try expect(saved.topicReviews.count == 1 && saved.weeklyReports.first?.modelCoverage != nil && saved.weeklyReports.first?.digestRows.allSatisfy { !$0.isExtractive } == true, "正式回顾混入本地摘录或未保存生成元数据")
        try await reopened.correctCaptureText(f.records[0].id, text: "[聊天·自己] 更正：Atlas 验证尚未完成。")
        let changed = await reopened.snapshot()
        try expect(changed.topicReviews.isEmpty && changed.weeklyReports.first?.isReadable == false, "来源更正后仍保留失效的模型总结")
    }
    static func migrationAndSchedule() throws {
        let state = try JSONDecoder().decode(RecallState.self, from: Data("{}".utf8))
        try expect(state.topicReviews.isEmpty && ReviewSchedule(template: ReviewTemplate(kind: .personal), scope: ReviewScope()).useModel, "旧数据不兼容或新计划仍默认本地生成")
    }
}
