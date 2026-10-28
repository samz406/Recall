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
        // Screen text with no chat marker: nothing in it is attributable to the user.
        let text = "一篇关于分页边界的文章说明了很多通用的做法和注意事项，这些内容并不是本人的表述。"
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
