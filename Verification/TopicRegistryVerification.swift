import Foundation
import RecallKit

/// 主题身份：别名映射到规范键，换个叫法仍是同一件事。
enum TopicRegistryVerification {
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }

    static func run() async throws {
        try aliasesMapToCanonicalKey()
        try await renamedTopicStaysOneTopic()
        print("PASS: 2 topic registry scenarios (alias mapping, renamed topic stays one)")
    }

    private static func aliasesMapToCanonicalKey() throws {
        let key = DailyKnowledgeEngine.topicKey
        let aliases = [key("一键发版上线"): key("一键发版功能")]
        try expect(DailyKnowledgeEngine.canonicalKey("一键发版上线", aliases: aliases) == key("一键发版功能"), "别名应映射到规范键")
        try expect(DailyKnowledgeEngine.canonicalKey("一键发版功能", aliases: aliases) == key("一键发版功能"), "规范名自身不变")
        let loop = [key("甲"): key("乙"), key("乙"): key("甲")]
        try expect(!DailyKnowledgeEngine.canonicalKey("甲", aliases: loop).isEmpty, "别名成环时不能死循环")
    }

    /// 两天用不同叫法记录同一件事：没有别名时是两个主题，写入别名后合成一个，来源取并集。
    private static func renamedTopicStaysOneTopic() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-topic-alias-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage)
        let calendar = Calendar(identifier: .gregorian)
        let day1 = calendar.date(byAdding: .day, value: -2, to: .now)!
        let day2 = calendar.date(byAdding: .day, value: -1, to: .now)!
        let first = CaptureRecord(eventTemplate: .manualMoment, createdAt: day1, sourceAppName: "合成验证",
            sourceBundleIdentifier: "example.topic-alias", contentHash: UUID().uuidString, ocrText: "合成：一键发版功能第一步", textOrigin: .userInput)
        let second = CaptureRecord(eventTemplate: .manualMoment, createdAt: day2, sourceAppName: "合成验证",
            sourceBundleIdentifier: "example.topic-alias", contentHash: UUID().uuidString, ocrText: "合成：一键发版上线发布", textOrigin: .userInput)
        try await store.addCapture(first)
        try await store.addCapture(second)
        try await store.upsertDailySummary(summary(day: day1, topic: "一键发版功能", source: first, title: "完成发版脚本"))
        try await store.upsertDailySummary(summary(day: day2, topic: "一键发版上线", source: second, title: "发版页面上线"))

        let before = await store.snapshot()
        let separate = MatterMemoryEngine().files(in: before)
        try expect(separate.count == 2, "没有别名时不同叫法是两个主题")

        try await store.saveTopicAliases([DailyKnowledgeEngine.topicKey("一键发版上线"): DailyKnowledgeEngine.topicKey("一键发版功能")])
        let after = await store.snapshot()
        let merged = MatterMemoryEngine().files(in: after)
        try expect(merged.count == 1, "写入别名后应合为一个主题")
        try expect(merged.first?.events.count == 2, "合并后的主题应保留两天的事件")
        try expect(Set(merged.first?.evidenceIDs ?? []) == [first.id, second.id], "合并后的来源应为两天的并集")
        try expect(merged.first?.title == "一键发版上线", "显示名应取最新一天的叫法")
    }

    private static func summary(day: Date, topic: String, source: CaptureRecord, title: String) -> DailySummary {
        let knowledge = DailyItemKnowledge(topic: topic, kind: .matter, status: "progressed", ownedByUser: true, quotes: [source.ocrText])
        let item = DailySummaryItem(id: UUID(), section: .progress, title: title, detail: title, evidenceIDs: [source.id], knowledge: knowledge)
        return DailySummary(day: day, content: title, sourceCaptureIDs: [source.id], todos: [], generationKind: .cloud, items: [item])
    }
}
