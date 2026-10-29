import CoreGraphics
import Foundation
import RecallKit

/// Synthetic checks for capture de-duplication, evidence cleanup and the lighter write path.
enum SummaryAccuracyVerification {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ModelReviewVerification.Failure(message: message) }
    }
    /// Answers the single direct-review request, quoting across lines and with a stray empty condition.
    actor Model: LLMResponding {
        var questions: [String] = []
        var bodies: [String] = []
        func log() -> ([String], [String]) { (questions, bodies) }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            questions.append(request.question); bodies.append(request.context[0].ocrText)
            let docs = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
            let id = docs[0]["id"] as! String
            let lines = (docs[0]["text"] as! String).components(separatedBy: "\n").filter { $0.hasPrefix("Atlas") }
            let item: [String: Any] = ["section": "progress", "title": "Atlas 分页验证已完成", "detail": "边界与空值用例已完成，原始结果已保留。",
                "owner": "unknown", "status": "completed", "explicitCommitment": false, "condition": "  ",
                // The model joins two source lines with a newline; locally each half is verbatim.
                "evidence": [["id": id, "quote": lines.prefix(2).joined(separator: "\n")]]]
            let coverage = docs.map { ["id": $0["id"]!, "disposition": "used"] as [String: Any] }
            let value: [String: Any] = ["overview": "完成分页验证。", "items": [item], "coverage": coverage]
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    static func run() async throws {
        try await captureDeduplicationAndFastWrite()
        try await conversationMarkers()
        try await evidenceCleanupAndRepeatedLines()
        try await structuredDailyKnowledge()
        try await dailyReviewsDriveTheMemoryTabs()
        try await legacyLedgerIsRebuilt()
        try await overclaimedOwnershipIsDemoted()
        try await unmarkedScreenWorkIsTheUsers()
        try await templatesSeparateTopicsByCategory()
        try timeRangesAreResolved()
        try await ledgerCurrencyCheckIsCheap()
        try await questionTermsAndTopicRetrieval()
        try await cleaningKeepsContentAndIsReversible()
        try await regeneratingEveryDayKeepsOldVersions()
        print("PASS: summary accuracy covers near-duplicate captures, fast writes, chat markers, quote repair and repeated lines")
    }

    static func captureDeduplicationAndFastWrite() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-accuracy-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try FileMemoryStore(storage: storage)
        let screen = (0..<8).map { "Atlas 第 \($0) 行：分页边界验证记录与结果" }.joined(separator: "\n")
        let first = CaptureRecord(eventTemplate: .workCheckpoint, createdAt: .now, sourceAppName: "合成", sourceBundleIdentifier: "example.a",
            contentHash: "h1", ocrText: screen)
        try await store.addCapture(first)
        let hit = await store.hasRecentHash("h1")
        try expect(hit, "刚写入的记录没有被近期哈希命中")
        // A clock tick changes one line; everything else is identical.
        let ticked = screen.replacingOccurrences(of: "Atlas 第 7 行：分页边界验证记录与结果", with: "10:31 Atlas 时钟")
        let near = await store.hasRecentNearDuplicate(text: ticked, bundleIdentifier: "example.a", threshold: 0.8)
        let otherApp = await store.hasRecentNearDuplicate(text: ticked, bundleIdentifier: "example.b", threshold: 0.8)
        let other = (0..<8).map { "完全不同的页面 \($0) 的另一件事情内容" }.joined(separator: "\n")
        let different = await store.hasRecentNearDuplicate(text: other, bundleIdentifier: "example.a")
        let expired = await store.hasRecentNearDuplicate(text: ticked, bundleIdentifier: "example.a", threshold: 0.8, now: .now.addingTimeInterval(60))
        try expect(near, "仅差一行的相邻截图没有判为重复")
        try expect(!otherApp, "不同应用的相似内容被误判为重复")
        try expect(!different, "不同内容被误判为重复")
        try expect(!expired, "超出时间窗口仍判为重复")
        // The fast write path must leave the saved state decodable and complete.
        let reopened = try FileMemoryStore(storage: storage)
        let ids = await reopened.snapshot().captures.map(\.id)
        try expect(ids == [first.id], "快速写入路径没有保存记录")
    }

    static func conversationMarkers() async throws {
        func line(_ text: String, _ rect: CGRect) -> PositionedTextLine { PositionedTextLine(text: text, boundingBox: rect) }
        let bubble = CGRect(x: 0.5, y: 0.6, width: 0.3, height: 0.05)
        let lines = [line("好的，我上午处理", bubble),
                     line("联系人列表里的一个很长的导航条目名称", CGRect(x: 0.05, y: 0.3, width: 0.3, height: 0.03)),
                     line("昨天 18:30", CGRect(x: 0.45, y: 0.9, width: 0.1, height: 0.03))]
        let layout = ConversationOCRLayout(contentBounds: CGRect(x: 0, y: 0, width: 1, height: 1), bubbles: [ConversationBubble(bounds: bubble, speaker: .user)])
        let text = ConversationOCRFormatter.format(lines, context: .messaging, layout: layout)
        try expect(text.contains("[聊天·自己] 好的，我上午处理"), "气泡内消息丢失角色")
        try expect(text.contains("[聊天·角色未知] [内容·片段] 联系人列表里的一个很长的导航条目名称"), "气泡外的界面文字仍被当作消息")
        try expect(text.contains("[聊天·角色未知] 昨天 18:30") && !text.contains("[内容·片段] 昨天 18:30"), "日期时间被误标为界面文字")
    }

    static func evidenceCleanupAndRepeatedLines() async throws {
        let text = "Atlas 分页边界验证第一条结论已经完成并保存。\nAtlas 空值用例第二条结论也已经完成并保存。\n菜单项 设置 帮助 窗口 与其他无关界面元素"
        let f = try await ModelReviewVerification.fixture(count: 3, raw: true, text: text)
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Model()
        let output = try await f.store.generateDirectDailyReview(day: f.records[0].createdAt, period: f.period, responder: model)
        let (_, bodies) = await model.log()
        // The same screen was recorded three times; each line is sent once.
        try expect(bodies.count == 1 && bodies[0].components(separatedBy: "Atlas 分页边界验证第一条结论").count == 2, "重复的 OCR 行被多次发送")
        // Cross-line quote repaired locally, empty condition normalized, no repair round needed.
        try expect(output.metrics.modelCalls == 1 && output.summary.generationKind == .cloud, "跨行引用没有在本地修复而是触发了额外请求")
    }
}

extension SummaryAccuracyVerification {
    /// Model that returns a topic and kind for each item so the structured result can feed other tabs.
    actor TopicModel: LLMResponding {
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            let docs = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
            let id = docs[0]["id"] as! String
            let line = (docs[0]["text"] as! String).components(separatedBy: "\n").first { $0.hasPrefix("[聊天·自己]") || $0.hasPrefix("Atlas") } ?? ""
            let own = line.replacingOccurrences(of: "[聊天·自己] ", with: "")
            let item: [String: Any] = ["section": "progress", "title": "Atlas 分页验证已完成", "detail": "边界与空值用例已完成，原始结果已保留。",
                "topic": "Atlas 分页", "kind": "matter", "owner": "user", "status": "completed", "explicitCommitment": false,
                "condition": NSNull(), "evidence": [["id": id, "quote": String(own.prefix(60))]]]
            let coverage = docs.map { ["id": $0["id"]!, "disposition": "used"] as [String: Any] }
            let value: [String: Any] = ["overview": "完成分页验证。", "items": [item], "coverage": coverage]
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    static func structuredDailyKnowledge() async throws {
        let f = try await ModelReviewVerification.fixture(count: 3, raw: true)
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let output = try await f.store.generateDirectDailyReview(day: f.records[0].createdAt, period: f.period, responder: TopicModel())
        let item = output.summary.items.first
        try expect(item?.knowledge?.topic == "Atlas 分页" && item?.knowledge?.kind == .matter && item?.knowledge?.ownedByUser == true,
            "每日回顾没有保存主题、类型和归属")
        let reopened = try FileMemoryStore(storage: f.storage)
        let saved = await reopened.snapshot().dailySummaries.first?.items.first
        try expect(saved?.knowledge?.topic == "Atlas 分页" && saved?.knowledge?.quotes.isEmpty == false, "结构化理解没有随回顾保存并读回")
        try expect(DirectDailyReviewEngine.cleanTopic("工作") == nil && DirectDailyReviewEngine.cleanTopic("发布流程页面改版") == "发布流程页面改版", "泛称主题没有被拒绝")
        let long = String(repeating: "这是一句很长的概述。", count: 30)
        let fitted = DirectDailyReviewEngine.fittedOverview(long, final: true)
        try expect(fitted.count <= 160 && fitted.hasSuffix("。"), "超长概览没有在句子边界截短")
        try expect(DirectDailyReviewEngine.fittedOverview("中间组不应有概览。", final: false).isEmpty, "中间分组的概览没有被清空")
        try expect(DirectDailyReviewEngine.cleanKind("preference", owned: false) == "reference", "非本人内容被标成偏好")
    }
}

extension SummaryAccuracyVerification {
    /// Daily reviews with structured items drive topics, long-term memory and the period review.
    actor PeriodModel: LLMResponding {
        var bodies: [String] = []
        func log() -> [String] { bodies }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            bodies.append(request.context[0].ocrText)
            let rows = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
            let own = rows.filter { ($0["kind"] as! String) == "matter" }
            let first = own[0]
            let quote = (first["title"] as! String)
            let item: [String: Any] = ["section": "progress", "title": "Atlas 分页验证从开始到完成", "detail": "三天内完成边界与空值验证，最后一天结果已保存。",
                "evidence": [["id": first["id"]!, "quote": quote], ["id": own.last!["id"]!, "quote": "跨行\n" + (own.last!["title"] as! String)]]]
            let value: [String: Any] = ["overview": "分页验证完成。", "items": [item]]
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    static func dailyReviewsDriveTheMemoryTabs() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-daily-driven-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try FileMemoryStore(storage: storage)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var records: [CaptureRecord] = []
        for offset in 1...3 {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            // Screen OCR with no chat markers: the pattern-based path cannot attribute any of it.
            let record = CaptureRecord(eventTemplate: .workCheckpoint, createdAt: day.addingTimeInterval(36_000), sourceAppName: "Orca",
                sourceBundleIdentifier: "example.orca", contentHash: UUID().uuidString,
                ocrText: "Atlas 分页边界验证第 \(offset) 天的结果记录与完整说明文字内容")
            try await store.addCapture(record); records.append(record)
        }
        try await store.updatePrivacy(PrivacySettings(cloudUseEnabled: true))
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .openAICompatible, model: "synthetic", apiKey: "verification-placeholder"))
        let before = await store.snapshot()
        try expect(MatterMemoryEngine().files(in: before).isEmpty, "没有模型理解时，屏幕 OCR 不应凭规则生成主题")
        for (index, record) in records.enumerated() {
            let day = calendar.startOfDay(for: record.createdAt)
            let knowledge = DailyItemKnowledge(topic: "Atlas 分页", kind: .matter, status: index == 0 ? "completed" : "inProgress",
                ownedByUser: true, quotes: [record.ocrText])
            var summary = DailySummary(day: day, content: "x", sourceCaptureIDs: [record.id], todos: [], generationKind: .cloud,
                items: [DailySummaryItem(section: .progress, title: "Atlas 分页边界验证第 \(index + 1) 天", detail: "结果已记录并保存。",
                    evidenceIDs: [record.id], knowledge: knowledge)])
            summary.items = [DailySummaryItem(section: .progress, title: "Atlas 分页边界验证第 \(index + 1) 天", detail: "结果已记录并保存。",
                evidenceIDs: [record.id], knowledge: knowledge)]
            try await store.commitDailySummary(summary, consolidation: PersonalIntelligenceEngine().consolidate(day: day, records: [record]))
        }
        try await store.organizeMemory(force: true)
        let state = await store.snapshot()
        let topics = MatterMemoryEngine().files(in: state)
        try expect(topics.count == 1 && topics[0].title == "Atlas 分页" && topics[0].events.count == 3 && topics[0].latest.status == .completed,
            "三天的每日回顾没有归并成一个以最终状态结尾的主题")
        try expect(!state.memoryKnowledge.claims.contains { $0.kind == .reference && $0.evidence.isEmpty }, "长期记忆含无来源线索")
        try expect(state.memoryKnowledge.claims.filter { $0.kind == .event }.count == 3, "事项没有作为长期记忆账本里的进展保存")
        // Period review: one call over the daily items, quotes re-cut to verbatim fragments.
        let model = PeriodModel()
        let period = ReviewPeriod(start: calendar.date(byAdding: .day, value: -3, to: today)!, end: today)
        let result = try await PeriodReviewFromDaily().generate(in: state, period: period, template: ReviewTemplate(kind: .personal), responder: model).draft
        let bodies = await model.log()
        let prompt = PeriodReviewFromDaily().prompt(label: "x", template: { var t = ReviewTemplate(kind: .work); t.length = .brief; t.tone = .formal; return t }(),
            topic: nil, feedback: "", itemLimit: 3, detailLimit: 120)
        try expect(prompt.contains("不超过 120 字") && prompt.contains("最多 3 项") && prompt.contains("语言克制、正式") && prompt.contains("交给同事阅读"),
            "篇幅、表达和模板类型没有进入周期回顾的提示词")
        try expect(bodies.count == 1 && result.items.count == 1 && !result.facts.isEmpty, "周期回顾没有只用一次调用完成，或没有保留来源")
        try expect(result.sourceVersions.keys.allSatisfy { id in records.contains { $0.id == id } }, "周期回顾的来源不是被引用的截图")
        // Deleting a screenshot removes the topic events that depended on it.
        _ = try await store.deleteCapture(id: records[0].id)
        let afterDelete = MatterMemoryEngine().files(in: await store.snapshot())
        try expect(afterDelete.first?.events.count == 2 && afterDelete.first?.latest.status != .completed, "删除来源后主题仍保留依赖它的事件")
    }
}

extension SummaryAccuracyVerification {
    static func legacyLedgerIsRebuilt() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-legacy-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        var state = RecallState()
        let record = CaptureRecord(eventTemplate: .workCheckpoint, sourceAppName: "Chrome", sourceBundleIdentifier: "example.chrome",
            contentHash: "legacy", ocrText: String(repeating: "一篇很长的文章段落，说明了很多事情而且包含足够多的文字内容。", count: 6))
        state.captures = [record]
        // A ledger written by the previous organization version, full of paragraph-level reference claims.
        var knowledge = MemoryKnowledge()
        knowledge.organizationVersion = 4; knowledge.updatedAt = .now
        knowledge.sourceVersions = [record.id.uuidString: MemoryKnowledgeEngine.version(of: record)]
        let iso = ISO8601DateFormatter().string(from: .now)
        let claimJSON = """
        [{"id":"\(UUID().uuidString)","key":"reference:legacy","subjectID":"reference:legacy","title":"旧线索","content":"旧的段落线索","kind":"reference",
        "state":"active","scope":"global","evidence":[{"captureID":"\(record.id.uuidString)","fragment":0,"quote":"旧的段落线索","speaker":"x","sourceVersion":"",
        "recordedAt":"\(iso)"}],"dependencies":[],"supersedes":[],"status":"explored","validFrom":"\(iso)","updatedAt":"\(iso)","explicit":false}]
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        knowledge.claims = try decoder.decode([MemoryClaim].self, from: Data(claimJSON.utf8))
        state.memoryKnowledge = knowledge
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: storage.stateURL)
        let store = try FileMemoryStore(storage: storage)
        try await store.organizeMemory(force: true)
        let rebuilt = await store.snapshot().memoryKnowledge
        try expect(rebuilt.organizationVersion == MemoryKnowledgeEngine.organizationVersion, "旧账本没有升级到新的整理版本")
        try expect(!rebuilt.claims.contains { $0.key == "reference:legacy" }, "旧版段落线索没有随升级清理")
    }
}

extension SummaryAccuracyVerification {
    /// Labels every item as the user's even though the only source is unattributed screen text.
    actor OverclaimingModel: LLMResponding {
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            let docs = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
            let id = docs[0]["id"] as! String
            let line = (docs[0]["text"] as! String).components(separatedBy: "\n").last { $0.count > 12 } ?? ""
            func item(_ section: String, _ title: String, _ commitment: Bool) -> [String: Any] {
                ["section": section, "title": title, "detail": "这条结论引用的是屏幕上的资料文字而不是本人表述。",
                 "topic": "资料阅读", "kind": "matter", "owner": "user", "status": commitment ? "pending" : "completed",
                 "explicitCommitment": commitment, "condition": NSNull(), "evidence": [["id": id, "quote": String(line.prefix(30))]]]
            }
            let value: [String: Any] = ["overview": "资料阅读。", "items": [item("progress", "阅读了一篇关于分页的资料", false), item("actions", "补齐分页边界验证", true)],
                "coverage": docs.map { ["id": $0["id"]!, "disposition": "used"] as [String: Any] }]
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    static func overclaimedOwnershipIsDemoted() async throws {
        // Saved material and the other party's words are explicitly marked: the model cannot make them the user's.
        let text = "[聊天·对方] 一篇关于分页边界的文章说明了很多通用的做法和注意事项，这些内容并不是本人的表述。\n[聊天·自己] [内容·资料] 分页边界的通用做法与注意事项整理，转发自他人。"
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-overclaim-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try FileMemoryStore(storage: storage)
        let now = Date.now
        try await store.addCapture(CaptureRecord(eventTemplate: .workCheckpoint, createdAt: now.addingTimeInterval(-5), sourceAppName: "Chrome",
            sourceBundleIdentifier: "example.chrome", contentHash: UUID().uuidString, ocrText: text, textOrigin: .screenOCR))
        try await store.updatePrivacy(PrivacySettings(cloudUseEnabled: true))
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .openAICompatible, model: "synthetic", apiKey: "verification-placeholder"))
        let period = ReviewPeriod(start: now.addingTimeInterval(-60), end: now)
        let output = try await store.generateDirectDailyReview(day: now, period: period, responder: OverclaimingModel())
        let items = output.summary.items
        try expect(!items.isEmpty, "错误归属的条目让整天回顾失败而不是被降级")
        try expect(!items.contains { $0.section == .actions }, "无法证明是本人承诺的待办没有被丢弃")
        try expect(items.allSatisfy { $0.knowledge?.ownedByUser != true }, "引用资料的条目仍被保存为本人事项")
    }
}

extension SummaryAccuracyVerification {
    /// Unmarked screen text (no speaker) judged by the model to be the user's own work counts as theirs.
    actor ScreenModel: LLMResponding {
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            let docs = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
            let id = docs[0]["id"] as! String
            let line = (docs[0]["text"] as! String).components(separatedBy: "\n").last { $0.count > 12 } ?? ""
            let item: [String: Any] = ["section": "progress", "title": "发布页改版已合并到主分支", "detail": "页面改版的代码已经合并，状态已更新。",
                "topic": "发布流程页面改版", "kind": "matter", "owner": "user", "status": "completed", "explicitCommitment": false,
                "condition": NSNull(), "evidence": [["id": id, "quote": String(line.prefix(30))]]]
            let value: [String: Any] = ["overview": "改版合并。", "items": [item],
                "coverage": docs.map { ["id": $0["id"]!, "disposition": "used"] as [String: Any] }]
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    static func unmarkedScreenWorkIsTheUsers() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-screen-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try FileMemoryStore(storage: storage)
        let now = Date.now
        try await store.addCapture(CaptureRecord(eventTemplate: .workCheckpoint, createdAt: now.addingTimeInterval(-5), sourceAppName: "Orca",
            sourceBundleIdentifier: "example.orca", contentHash: UUID().uuidString,
            ocrText: "发布流程页面改版的代码已经合并到主分支，部署状态与验证结果已更新。", textOrigin: .screenOCR))
        try await store.updatePrivacy(PrivacySettings(cloudUseEnabled: true))
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .openAICompatible, model: "synthetic", apiKey: "verification-placeholder"))
        let output = try await store.generateDirectDailyReview(day: now, period: ReviewPeriod(start: now.addingTimeInterval(-60), end: now), responder: ScreenModel())
        let knowledge = output.summary.items.first?.knowledge
        try expect(knowledge?.ownedByUser == true && knowledge?.kind == .matter, "没有说话人标记的屏幕工作内容被降成资料，无法形成主题")
    }
}

extension SummaryAccuracyVerification {
    static func templatesSeparateTopicsByCategory() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-template-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try FileMemoryStore(storage: storage)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let rows: [(String, String?)] = [("发布流程页面改版", "work"), ("成都马拉松半马记录", "personal"), ("英语口语练习", "learning"), ("未能判断的事情", nil)]
        for (index, row) in rows.enumerated() {
            let day = calendar.date(byAdding: .day, value: -(index + 1), to: today)!
            let record = CaptureRecord(eventTemplate: .workCheckpoint, createdAt: day.addingTimeInterval(36_000), sourceAppName: "Orca",
                sourceBundleIdentifier: "example.orca", contentHash: UUID().uuidString, ocrText: "\(row.0) 当天的内容记录与完整说明文字", textOrigin: .screenOCR)
            try await store.addCapture(record)
            let knowledge = DailyItemKnowledge(topic: row.0, kind: .matter, status: "completed", ownedByUser: true, quotes: [record.ocrText], category: row.1)
            let item = DailySummaryItem(section: .progress, title: "\(row.0)已经完成", detail: "当天的结果已经记录并保存下来。", evidenceIDs: [record.id], knowledge: knowledge)
            var summary = DailySummary(day: day, content: "x", sourceCaptureIDs: [record.id], todos: [], generationKind: .cloud, items: [item])
            summary.items = [item]
            try await store.commitDailySummary(summary, consolidation: PersonalIntelligenceEngine().consolidate(day: day, records: [record]))
        }
        try await store.updatePrivacy(PrivacySettings(cloudUseEnabled: true))
        let state = await store.snapshot()
        let period = ReviewPeriod(start: calendar.date(byAdding: .day, value: -6, to: today)!, end: today)
        func topics(_ kind: ReviewTemplateKind) throws -> Set<String> {
            let prepared = try PeriodReviewFromDaily().prepare(in: state, period: period, template: ReviewTemplate(kind: kind))
            return Set(prepared.titles())
        }
        let work = try topics(.work), learning = try topics(.learning), personal = try topics(.personal)
        try expect(work == ["发布流程页面改版"], "工作周报混入了生活、学习或未分类的主题：\(work)")
        try expect(learning == ["英语口语练习"], "学习回顾混入了工作或生活的主题：\(learning)")
        try expect(personal.count == 4, "我的一周没有覆盖全部主题：\(personal)")
        let prepared = try PeriodReviewFromDaily().prepare(in: state, period: period, template: ReviewTemplate(kind: .personal))
        try expect(prepared.categories().contains("work") && prepared.categories().contains("learning"), "类别没有进入传给模型的内容")
    }
}

extension SummaryAccuracyVerification {
    static func timeRangesAreResolved() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!; calendar.firstWeekday = 2
        // Wednesday, 28 October 2026, 15:00.
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 15))!
        func resolve(_ text: String) -> (String, String)? {
            guard let range = MemoryTimeRangeResolver().resolve(text, now: now, calendar: calendar) else { return nil }
            let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "MM-dd"
            return (f.string(from: range.startDate), f.string(from: min(range.endDate, now)))
        }
        try expect(resolve("10月25日做了什么")?.0 == "10-25" && resolve("10月25日做了什么")?.1 == "10-26", "具体日期没有解析为当天")
        try expect(resolve("2026年10月20日的记录")?.0 == "10-20", "带年份的日期没有解析")
        try expect(resolve("上周三我在做什么")?.0 == "10-21", "上周三没有解析为上周的周三")
        try expect(resolve("周二做了什么")?.0 == "10-27", "周二没有解析为本周已过的周二")
        try expect(resolve("周五做了什么")?.0 == "10-23", "尚未到来的周五应取上一个周五")
        try expect(resolve("前天做了什么")?.0 == "10-26", "前天没有解析")
        try expect(resolve("10月份的进展")?.0 == "10-01", "整月没有解析")
        try expect(resolve("上个月做了什么")?.0 == "09-01" && resolve("上个月做了什么")?.1 == "10-01", "上个月没有解析为整月")
        // A date later in the year than today has not happened yet; the question can only mean last year's.
        let past = MemoryTimeRangeResolver().resolve("12月25日", now: now, calendar: calendar)
        try expect(past.map { calendar.component(.year, from: $0.startDate) == 2025 } == true, "还没到的日期不应解析到今年")
        try expect(resolve("妙妙什么时候过生日") == nil, "没有时间词的问题被当作带时间范围")
        try expect(resolve("今天记录了什么")?.0 == "10-28", "原有的今天解析被破坏")
        try expect(resolve("最近三天做了什么")?.0 == "10-26", "原有的最近N天解析被破坏")
        print("PASS: time expressions cover dates, weekdays, months and the previous behaviour")
    }
}

extension SummaryAccuracyVerification {
    static func ledgerCurrencyCheckIsCheap() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-ledger-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        var state = RecallState()
        state.captures = (0..<2400).map { index in
            CaptureRecord(eventTemplate: .workCheckpoint, createdAt: Date.now.addingTimeInterval(-Double(index) * 60), sourceAppName: "合成",
                sourceBundleIdentifier: "example.synthetic", contentHash: "h\(index)",
                ocrText: String(repeating: "合成记录正文，用来衡量整库检查的耗时。\(index) ", count: 40), textOrigin: .screenOCR)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: storage.stateURL)
        let store = try FileMemoryStore(storage: storage)
        try await store.organizeMemory()
        let begin = Date.now
        let current = await store.isMemoryLedgerCurrent()
        let currentMs = Int(Date.now.timeIntervalSince(begin) * 1000)
        try expect(current, "刚整理过的账本被判为过期")
        let before = Date.now
        try await store.organizeMemoryIfNeeded()
        let skipMs = Int(Date.now.timeIntervalSince(before) * 1000)
        try expect(skipMs < 1500, "账本最新时仍然花了 \(skipMs) 毫秒")
        // A new capture makes the ledger stale, and the next question reconciles it.
        try await store.addCapture(CaptureRecord(eventTemplate: .workCheckpoint, sourceAppName: "合成", sourceBundleIdentifier: "example.synthetic",
            contentHash: "new", ocrText: "新增的一条记录内容", textOrigin: .screenOCR))
        let stale = await store.isMemoryLedgerCurrent()
        try expect(!stale, "新增记录后账本没有被判为过期")
        print("PASS: ledger currency check on 2400 records took \(currentMs) ms, skipped reconcile in \(skipMs) ms")
    }
}

extension SummaryAccuracyVerification {
    static func questionTermsAndTopicRetrieval() async throws {
        let terms = QuestionTerms.topicTerms("关于 Recall 后台理解流程，请找回上次的进展、已确认的结论和仍缺少的信息。")
        try expect(terms.contains("recall") && terms.contains("后台理解流程") && terms.contains("理解"), "主题词没有保留：\(terms)")
        let generic = ["上次", "进展", "结论", "信息", "已确", "确认", "缺少", "仍缺", "找回"]
        try expect(generic.allSatisfy { !terms.contains($0) }, "模板词仍然参与检索：\(terms)")
        try expect(QuestionTerms.topicTerms("今天记录了什么").isEmpty || !QuestionTerms.topicTerms("今天记录了什么").contains("什么"), "停用词没有剔除")
        // A topic named in the question is found by its identifying words, and its first and latest states both come back.
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-topic-q-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try FileMemoryStore(storage: storage)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var records: [CaptureRecord] = []
        let names = [("Recall 后台理解流程", "inProgress"), ("Recall 后台理解流程", "blocked"), ("Recall 后台理解流程", "completed"), ("英语口语练习", "completed")]
        for (index, entry) in names.enumerated() {
            let day = calendar.date(byAdding: .day, value: -(names.count - index), to: today)!
            let record = CaptureRecord(eventTemplate: .workCheckpoint, createdAt: day.addingTimeInterval(36_000), sourceAppName: "Orca",
                sourceBundleIdentifier: "example.orca", contentHash: UUID().uuidString, ocrText: "\(entry.0) 第 \(index + 1) 天的记录与说明文字内容", textOrigin: .screenOCR)
            try await store.addCapture(record); records.append(record)
            let knowledge = DailyItemKnowledge(topic: entry.0, kind: .matter, status: entry.1, ownedByUser: true, quotes: [record.ocrText], category: "work")
            let item = DailySummaryItem(section: .progress, title: "\(entry.0)第\(index + 1)天进展", detail: "当天的状态已经记录并保存下来。", evidenceIDs: [record.id], knowledge: knowledge)
            var summary = DailySummary(day: day, content: "x", sourceCaptureIDs: [record.id], todos: [], generationKind: .cloud, items: [item])
            summary.items = [item]
            try await store.commitDailySummary(summary, consolidation: PersonalIntelligenceEngine().consolidate(day: day, records: [record]))
        }
        try await store.organizeMemory(force: true)
        let state = await store.snapshot()
        let found = DailyKnowledgeEngine().topics(matching: "关于后台理解流程，请找回上次的进展", in: state)
        try expect(found.map(\.title) == ["Recall 后台理解流程"], "提到主题名的问题没有找到该主题：\(found.map(\.title))")
        try expect(DailyKnowledgeEngine().topics(matching: "请找回上次的进展和结论", in: state).isEmpty, "只有模板词的问题不应命中任何主题")
        let plan = MemoryRetrievalEngine().plan(question: "关于后台理解流程，请找回上次的进展", state: state, fallback: [])
        let titles = plan.evidence.map(\.ocrText).joined(separator: "\n")
        try expect(titles.contains("第1天") && titles.contains("第3天"), "主题的最早与最新状态没有同时进入证据")
        try expect(!titles.contains("英语口语练习"), "无关主题混入了证据")
        print("PASS: question terms drop template words and a named topic returns its first, changed and latest states")
    }
}

extension SummaryAccuracyVerification {
    static func cleaningKeepsContentAndIsReversible() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-clean-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try FileMemoryStore(storage: storage)
        let now = Date.now
        let page = "Chrome\n文件\n编辑\n窗口\n帮助\nG\n发布流程页面改版的代码已经合并到主分支\n部署状态与验证结果已经更新完成"
        var originals: [CaptureRecord] = []
        for offset in 0..<3 {
            let record = CaptureRecord(eventTemplate: .workCheckpoint, createdAt: now.addingTimeInterval(Double(-30 + offset * 10)), sourceAppName: "Chrome",
                sourceBundleIdentifier: "example.chrome", contentHash: UUID().uuidString, ocrText: page + (offset == 2 ? "\n新增的一行真实内容说明文字" : ""), textOrigin: .screenOCR)
            try await store.addCapture(record); originals.append(record)
        }
        let typed = CaptureRecord(eventTemplate: .manualMoment, createdAt: now, sourceAppName: "手动", sourceBundleIdentifier: "im.recall.app",
            contentHash: UUID().uuidString, ocrText: "帮助\n窗\n我自己写的一行内容", textOrigin: .userInput)
        try await store.addCapture(typed)
        let preview = try await store.cleanCaptureText(dryRun: true)
        let untouched = await store.snapshot().captures.allSatisfy { $0.correctedText == nil }
        try expect(untouched, "预览模式修改了数据")
        // Record 2 repeats record 1 entirely, so nothing is left of it and it stays as it was.
        try expect(preview.changed == 2 && preview.skippedEmpty == 1 && preview.removedShort > 0 && preview.removedRepeated > 0,
            "预览统计不对：改动 \(preview.changed)，会变空 \(preview.skippedEmpty)")
        try await store.cleanCaptureText(dryRun: false)
        let state = await store.snapshot()
        let first = state.captures.first { $0.id == originals[0].id }!, last = state.captures.first { $0.id == originals[2].id }!
        try expect(first.correctedText?.contains("发布流程页面改版") == true && first.correctedText?.contains("帮助") == false, "菜单词没有被清掉，或正文丢失")
        try expect(first.ocrText == originals[0].ocrText, "清洗改动了原文")
        let second = state.captures.first { $0.id == originals[1].id }!
        try expect(second.correctedText == nil, "同一应用里重复的整屏内容没有被跳过（应保持原样或为空）")
        try expect(last.correctedText?.contains("新增的一行真实内容说明文字") == true && last.correctedText?.contains("发布流程页面改版") == false, "新增内容丢失，或重复行没有去掉")
        let user = state.captures.first { $0.id == typed.id }!
        try expect(user.correctedText == nil && user.ocrText.contains("我自己写的一行内容"), "用户手写的记录被清洗了")
        // Reverting is the app's existing "恢复原始文字".
        try await store.correctCaptureText(originals[0].id, text: nil)
        let reverted = await store.snapshot().captures.first { $0.id == originals[0].id }!
        try expect(reverted.correctedText == nil && reverted.ocrText == originals[0].ocrText, "无法恢复原始文字")
        print("PASS: cleaning drops menu words and repeated lines, keeps content and user text, and can be reverted")
    }
}

extension SummaryAccuracyVerification {
    /// Regenerating every day that has records, one call per day, keeping the previous version of each review.
    static func regeneratingEveryDayKeepsOldVersions() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-regen-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try FileMemoryStore(storage: storage)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var days: [Date] = []
        for offset in [5, 3, 2] {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            days.append(day)
            try await store.addCapture(CaptureRecord(eventTemplate: .workCheckpoint, createdAt: day.addingTimeInterval(36_000), sourceAppName: "Orca",
                sourceBundleIdentifier: "example.orca", contentHash: UUID().uuidString,
                ocrText: "发布流程页面改版的代码已经合并到主分支，部署状态与验证结果已更新。", textOrigin: .screenOCR))
        }
        try await store.updatePrivacy(PrivacySettings(cloudUseEnabled: true))
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .openAICompatible, model: "synthetic", apiKey: "verification-placeholder"))
        let model = ScreenModel()
        for day in days {
            let period = ReviewPeriod(start: day, end: calendar.date(byAdding: .day, value: 1, to: day)!)
            _ = try await store.generateDirectDailyReview(day: day, period: period, responder: model)
        }
        // Second pass over the same days replaces each review and keeps the first as a version.
        for day in days {
            let period = ReviewPeriod(start: day, end: calendar.date(byAdding: .day, value: 1, to: day)!)
            _ = try await store.generateDirectDailyReview(day: day, period: period, responder: model)
        }
        let state = await store.snapshot()
        try expect(state.dailySummaries.count == 3, "每天应只有一份当前回顾，实际 \(state.dailySummaries.count) 份")
        try expect(state.dailySummaries.allSatisfy { ($0.versions ?? []).count == 1 }, "重新生成没有保留上一版")
        try expect(state.dailySummaries.allSatisfy { $0.items.first?.knowledge?.topic == "发布流程页面改版" }, "重新生成的回顾不是结构化格式")
        print("PASS: regenerating every day replaces each review, keeps the previous version and writes structured items")
    }
}
