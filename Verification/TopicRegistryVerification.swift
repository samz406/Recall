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
        try identitySurvivesRenameAndMerge()
        try await migrationIsIdempotent()
        print("PASS: 4 topic registry scenarios (alias mapping, renamed topic stays one, stable identity, idempotent migration)")
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

    /// 改名、合并、删除都作用在稳定 UUID 上；旧 ID 通过迁移表仍能解析。
    private static func identitySurvivesRenameAndMerge() throws {
        var registry = TopicRegistry()
        let first = registry.resolveOrCreate(name: "一键发版功能", at: .now)
        registry.rename(id: first.id, to: "一键发版上线")
        try expect(registry.topic(forName: "一键发版功能")?.id == first.id, "旧名应解析到同一主题")
        try expect(registry.topic(forName: "一键发版上线")?.id == first.id, "新名也应解析到同一主题")
        try expect(registry.topics.count == 1, "改名不应新建主题")

        let second = registry.resolveOrCreate(name: "聊天多段回复合并", at: .now)
        registry.merge(second.id, into: first.id)
        try expect(registry.topics.count == 1, "合并后应只剩一个主题")
        try expect(registry.topic(forName: "聊天多段回复合并")?.id == first.id, "被合并的名字应成为别名")

        var legacy = TopicRegistry(topics: registry.topics, legacyAliases: ["topic:oldkey": first.id])
        try expect(legacy.canonicalID("topic:oldkey") == "topic:" + first.id.uuidString, "旧 ID 应归一为稳定 ID")

        legacy.remove(id: first.id)
        try expect(legacy.topics.isEmpty && legacy.topic(forName: "一键发版功能") == nil, "删除主题应连带删除别名")
        try expect(legacy.legacyAliases.isEmpty, "删除主题应清理指向它的旧 ID 映射")
    }

    /// 同一存档迁移两次得到同一组 UUID，旧主题 ID 仍能映射。
    private static func migrationIsIdempotent() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-topic-migrate-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage)
        let source = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "合成验证",
            sourceBundleIdentifier: "example.topic-migrate", contentHash: UUID().uuidString, ocrText: "合成：迁移夹具", textOrigin: .userInput)
        try await store.addCapture(source)
        try await store.upsertDailySummary(summary(day: .now, topic: "迁移主题", source: source, title: "迁移夹具条目"))
        let state = await store.snapshot()
        let once = TopicRegistry.migrated(from: state)
        let twice = TopicRegistry.migrated(from: state)
        try expect(once.topics.map(\.id) == twice.topics.map(\.id), "迁移不是幂等的")
        try expect(once.topics.first?.title == "迁移主题", "迁移应保留主题名")
        try expect(once.legacyAliases.keys.contains("topic:" + DailyKnowledgeEngine.topicKey("迁移主题")), "应记录旧主题 ID 映射")
    }

    private static func summary(day: Date, topic: String, source: CaptureRecord, title: String) -> DailySummary {
        let knowledge = DailyItemKnowledge(topic: topic, kind: .matter, status: "progressed", ownedByUser: true, quotes: [source.ocrText])
        let item = DailySummaryItem(id: UUID(), section: .progress, title: title, detail: title, evidenceIDs: [source.id], knowledge: knowledge)
        return DailySummary(day: day, content: title, sourceCaptureIDs: [source.id], todos: [], generationKind: .cloud, items: [item])
    }
}
