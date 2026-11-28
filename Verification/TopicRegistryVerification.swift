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
        try await savedReviewRegistersTopic()
        try lifecycleFollowsEvidenceAndUserMark()
        try await deletingTopicKeepsRecords()
        try await projectGrouping()
        try await renameShelveAndAutoWake()
        print("PASS: 9 topic registry scenarios (alias mapping, renamed topic stays one, stable identity, idempotent migration, review sync, lifecycle, deletion keeps records, project grouping, rename/shelve/auto-wake)")
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

    /// 启动迁移：旧存档（没有登记表）在打开时补齐，重复打开得到同一组 UUID。
    private static func migrationIsIdempotent() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-topic-migrate-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let source = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "合成验证",
            sourceBundleIdentifier: "example.topic-migrate", contentHash: UUID().uuidString, ocrText: "合成：迁移夹具", textOrigin: .userInput)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(RecallState(captures: [source],
            dailySummaries: [summary(day: .now, topic: "迁移主题", source: source, title: "迁移夹具条目")])).write(to: storage.stateURL)
        let first = try verificationStore(storage: storage)
        let once = await first.snapshot().topicRegistry
        try expect(once.topics.count == 1 && once.topics.first?.title == "迁移主题", "启动时没有迁移旧主题")
        try expect(once.legacyAliases["topic:" + DailyKnowledgeEngine.topicKey("迁移主题")] == once.topics.first?.id, "应记录旧主题 ID 映射")
        let second = try verificationStore(storage: storage)
        let twice = await second.snapshot().topicRegistry
        try expect(twice.topics.map(\.id) == once.topics.map(\.id), "迁移不是幂等的")
    }

    /// 每日回顾保存后，主题进入登记表；同名第二天只刷新最近活动时间，不新建。
    private static func savedReviewRegistersTopic() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-topic-sync-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage)
        let day1 = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        let day2 = Date.now
        let first = CaptureRecord(eventTemplate: .manualMoment, createdAt: day1, sourceAppName: "合成验证",
            sourceBundleIdentifier: "example.topic-sync", contentHash: UUID().uuidString, ocrText: "合成：发版第一步", textOrigin: .userInput)
        let second = CaptureRecord(eventTemplate: .manualMoment, createdAt: day2, sourceAppName: "合成验证",
            sourceBundleIdentifier: "example.topic-sync", contentHash: UUID().uuidString, ocrText: "合成：发版第二步", textOrigin: .userInput)
        try await store.addCapture(first)
        try await store.addCapture(second)
        try await store.upsertDailySummary(summary(day: day1, topic: "发版流水线", source: first, title: "开始搭流水线"))
        let afterFirst = await store.snapshot().topicRegistry
        try expect(afterFirst.topics.count == 1 && afterFirst.topics.first?.title == "发版流水线", "保存回顾后主题应进入登记表")
        let registeredID = afterFirst.topics.first?.id
        try await store.upsertDailySummary(summary(day: day2, topic: "发版流水线", source: second, title: "流水线跑通"))
        let afterSecond = await store.snapshot().topicRegistry
        try expect(afterSecond.topics.count == 1 && afterSecond.topics.first?.id == registeredID, "同名第二天不应新建主题")
        try expect(afterSecond.topics.first?.lastEventAt.map { Calendar.current.isDate($0, inSameDayAs: day2) } == true, "最近活动时间没有刷新")
    }

    /// 状态推断：完成事件算完成；14 天没有动静算搁置；用户手动标记优先。
    private static func lifecycleFollowsEvidenceAndUserMark() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12))!
        func file(daysAgo: Int, status: WorkEpisodeStatus) -> MatterFile {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            let event = MatterEvent(id: UUID(), title: "t", detail: "d", recordedAt: day, eventAt: day,
                                    status: status, evidenceIDs: [UUID()], nextAction: nil)
            return MatterFile(id: "topic:x", title: "x", events: [event])
        }
        try expect(TopicRegistry.lifecycle(for: file(daysAgo: 2, status: .progressed), topic: nil, now: now, calendar: calendar) == .active, "近期未完成应为进行中")
        try expect(TopicRegistry.lifecycle(for: file(daysAgo: 30, status: .progressed), topic: nil, now: now, calendar: calendar) == .dormant, "超过 14 天没有动静应为搁置")
        try expect(TopicRegistry.lifecycle(for: file(daysAgo: 2, status: .completed), topic: nil, now: now, calendar: calendar) == .done, "最近事件完成应为已完成")
        var topic = Topic(title: "x")
        topic.manualLifecycle = .done
        try expect(TopicRegistry.lifecycle(for: file(daysAgo: 1, status: .progressed), topic: topic, now: now, calendar: calendar) == .done, "用户手动标记应优先")
        topic.manualLifecycle = nil
        try expect(TopicRegistry.lifecycle(for: file(daysAgo: 1, status: .progressed), topic: topic, now: now, calendar: calendar) == .active, "清除手动标记后应回到推断")
    }

    /// 删除主题清理登记表、小结与完成标记，但不动原始记录。
    private static func deletingTopicKeepsRecords() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-topic-delete-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage)
        let source = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "合成验证",
            sourceBundleIdentifier: "example.topic-delete", contentHash: UUID().uuidString, ocrText: "合成：删除夹具", textOrigin: .userInput)
        try await store.addCapture(source)
        try await store.upsertDailySummary(summary(day: .now, topic: "待删主题", source: source, title: "待删条目"))
        let before = await store.snapshot()
        guard let topic = before.topicRegistry.topics.first else { throw Failure(message: "应已登记主题") }
        let fileID = "topic:" + topic.id.uuidString
        try await store.saveMatterCorrection(MatterCorrection(evidenceIDs: [source.id], kind: .completed, text: "待删主题", topicID: fileID))
        try await store.deleteTopic(id: fileID)
        let after = await store.snapshot()
        try expect(after.topicRegistry.topics.isEmpty, "删除后登记表不应残留该主题")
        try expect(after.topicRegistry.legacyAliases.isEmpty, "删除后不应残留旧 ID 映射")
        try expect(!after.matterCorrections.contains { $0.topicID == fileID }, "删除后不应残留完成标记")
        try expect(after.captures.contains { $0.id == source.id }, "删除主题不应删除原始记录")
    }

    /// 项目只是两级分组：只能挂到项目上，删除项目时子主题回到顶层。
    private static func projectGrouping() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-project-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage)
        let source = CaptureRecord(eventTemplate: .manualMoment, createdAt: .now, sourceAppName: "合成验证",
            sourceBundleIdentifier: "example.project", contentHash: UUID().uuidString, ocrText: "合成：项目夹具", textOrigin: .userInput)
        try await store.addCapture(source)
        try await store.upsertDailySummary(summary(day: .now, topic: "发版流水线", source: source, title: "项目夹具条目"))
        guard let project = try await store.createProject(title: "Recall 发布") else { throw Failure(message: "应创建项目") }
        var registry = await store.snapshot().topicRegistry
        guard let topic = registry.topics.first(where: { !$0.isProject }) else { throw Failure(message: "应已有主题") }

        // 不能挂到普通主题上（只允许两级）。
        try expect(!registry.setParent(topic.id, of: topic.id), "不允许自指")
        try expect(!registry.setParent(registry.topics.first?.id, of: topic.id) || registry.topics.first?.isProject == true, "普通主题不能作为父级")
        try expect(registry.setParent(project.id, of: topic.id), "应能挂到项目下")

        try await store.setTopicParent(topicID: "topic:" + topic.id.uuidString, parentID: "topic:" + project.id.uuidString)
        registry = await store.snapshot().topicRegistry
        try expect(registry.topic(id: topic.id)?.parentID == project.id, "所属项目没有写入")
        let grouped = TopicListPresentation.groupedByProject(
            [MatterFile(id: "topic:" + topic.id.uuidString, title: topic.title,
                        events: [MatterEvent(id: UUID(), title: topic.title, detail: "d", recordedAt: .now,
                                             status: .progressed, evidenceIDs: [source.id], nextAction: nil)])],
            registry: registry)
        try expect(grouped.count == 1 && grouped.first?.project?.id == project.id, "应按项目分组")

        try await store.deleteProject(id: "topic:" + project.id.uuidString)
        registry = await store.snapshot().topicRegistry
        try expect(registry.topic(id: project.id) == nil, "项目应被删除")
        try expect(registry.topic(id: topic.id)?.parentID == nil, "删除项目后子主题应回到顶层")
        try expect(registry.topic(id: topic.id) != nil, "删除项目不应删除主题")
    }

    /// 主题重命名、手动搁置（移出今天接着干）与后续新进展自动唤醒，以及手动记录主题直接归入项目。
    private static func renameShelveAndAutoWake() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-topic-shelve-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let source = CaptureRecord(eventTemplate: .manualMoment, createdAt: yesterday, sourceAppName: "合成验证",
            sourceBundleIdentifier: "example.shelve", contentHash: UUID().uuidString, ocrText: "合成：帮助入口改造 PR 已合入", textOrigin: .userInput)
        try await store.addCapture(source)
        try await store.upsertDailySummary(summary(day: yesterday, topic: "帮助入口移除", source: source, title: "帮助入口改造已合入但未发版"))

        var state = await store.snapshot()
        var files = MatterMemoryEngine().files(in: state)
        guard let file = files.first else { throw Failure(message: "未生成初始主题") }
        let initialResume = LocalBriefing.resume(in: state, matters: files)
        try expect(initialResume.contains { $0.kind == .openMatter && $0.topicTitle == "帮助入口移除" && $0.status == .progressed }, "接着干应携带主题名与结构化状态")

        // 重命名后显示名立即更新，旧名保留为别名。
        let renamed = try await store.renameTopic(id: file.id, fallbackTitle: file.title, to: "帮助中心入口清理")
        try expect(renamed, "重命名主题应成功")
        state = await store.snapshot()
        files = MatterMemoryEngine().files(in: state)
        try expect(files.first?.title == "帮助中心入口清理", "重命名后主题列表显示名应立即变为新名称")
        try expect(state.topicRegistry.topic(forName: "帮助入口移除")?.title == "帮助中心入口清理", "旧名应能通过别名解析到新名称")

        // 先放一放（搁置）：不伪造完成更正，立即移出今天接着干，并进入已搁置分组。
        try await store.setTopicLifecycle(id: file.id, fallbackTitle: "帮助中心入口清理", lifecycle: .dormant)
        state = await store.snapshot()
        files = MatterMemoryEngine().files(in: state)
        try expect(state.matterCorrections.isEmpty, "先放一放不应伪造已完成更正")
        try expect(!LocalBriefing.resume(in: state, matters: files).contains { $0.kind == .openMatter }, "搁置后的主题不应继续出现在今天接着干")
        let split = TopicListPresentation.sections(files, registry: state.topicRegistry)
        try expect(split.dormant.count == 1 && split.active.isEmpty, "搁置后的主题应进入已搁置分组")

        // 新一天出现未完新进展时，自动唤醒回到进行中与今天接着干。
        let newerSource = CaptureRecord(eventTemplate: .manualMoment, createdAt: today.addingTimeInterval(3600), sourceAppName: "合成验证",
            sourceBundleIdentifier: "example.shelve", contentHash: UUID().uuidString, ocrText: "合成：开始灰度验证帮助中心入口清理", textOrigin: .userInput)
        try await store.addCapture(newerSource)
        try await store.upsertDailySummary(summary(day: today, topic: "帮助入口移除", source: newerSource, title: "开始灰度验证帮助中心入口清理"))
        state = await store.snapshot()
        files = MatterMemoryEngine().files(in: state)
        try expect(TopicListPresentation.sections(files, registry: state.topicRegistry).active.count == 1, "新一天的新进展应自动唤醒已搁置主题")
        try expect(LocalBriefing.resume(in: state, matters: files).contains { $0.kind == .openMatter && $0.topicTitle == "帮助中心入口清理" }, "唤醒后仍应保持用户重命名后的主题名")

        // 尚未经过每日回顾迁移的手动记录主题也应支持直接归入项目分组。
        let firstNoteAt = Date.now.addingTimeInterval(-60)
        _ = try await store.addManualMatter(ManualMatterNote(title: "未迁移手动事项", detail: "合成手动进展", status: .progressed, eventAt: firstNoteAt), now: firstNoteAt)
        guard let project = try await store.createProject(title: "合成迭代项目") else { throw Failure(message: "创建项目失败") }
        state = await store.snapshot()
        files = MatterMemoryEngine().files(in: state)
        guard let manualFile = files.first(where: { $0.title == "未迁移手动事项" }) else { throw Failure(message: "缺少手动记录主题") }
        try await store.setTopicParent(topicID: manualFile.id, parentID: "topic:" + project.id.uuidString)
        state = await store.snapshot()
        files = MatterMemoryEngine().files(in: state)
        let grouped = TopicListPresentation.groupedByProject(files, registry: state.topicRegistry)
        try expect(grouped.contains { $0.project?.id == project.id && $0.files.contains { $0.title == "未迁移手动事项" } }, "手动记录主题未能归入项目分组")

        // 先放下的主题在补记「做完了」后应直接转入已做完，不再滞留于已搁置。
        try await store.setTopicLifecycle(id: manualFile.id, fallbackTitle: "未迁移手动事项", lifecycle: .dormant)
        let doneNoteAt = Date.now
        _ = try await store.addManualMatter(ManualMatterNote(title: "未迁移手动事项", detail: "全部验证通过并结项", status: .completed, eventAt: doneNoteAt), now: doneNoteAt)
        state = await store.snapshot()
        files = MatterMemoryEngine().files(in: state)
        let afterDoneSections = TopicListPresentation.sections(files, registry: state.topicRegistry)
        try expect(afterDoneSections.done.contains { $0.title == "未迁移手动事项" } && !afterDoneSections.dormant.contains { $0.title == "未迁移手动事项" },
                   "已搁置主题记下做完了结果后应进入已做完分组")
    }

    private static func summary(day: Date, topic: String, source: CaptureRecord, title: String) -> DailySummary {
        let knowledge = DailyItemKnowledge(topic: topic, kind: .matter, status: "progressed", ownedByUser: true, quotes: [source.ocrText])
        let item = DailySummaryItem(id: UUID(), section: .progress, title: title, detail: title, evidenceIDs: [source.id], knowledge: knowledge)
        return DailySummary(day: day, content: title, sourceCaptureIDs: [source.id], todos: [], generationKind: .cloud, items: [item])
    }
}
