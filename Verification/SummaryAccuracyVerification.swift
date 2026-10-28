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
        try expect(DirectDailyReviewEngine.cleanKind("preference", owned: false) == "reference", "非本人内容被标成偏好")
    }
}
