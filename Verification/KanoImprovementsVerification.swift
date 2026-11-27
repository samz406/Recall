import CoreGraphics
import Foundation
import RecallKit

/// Kano round: privacy preflight, text saves and notes, keyless local models, local briefs,
/// notification budget and new-install defaults. Synthetic data only; no network, screen or Keychain.
enum KanoImprovementsVerification {
    private struct Failure: LocalizedError { var errorDescription: String? }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(errorDescription: message) }
    }

    static func run() async throws {
        try privacyDecisions()
        try defaultsAndMigration()
        try await capturePreflight()
        try await textSavesAndNotes()
        try localModelEndpoints()
        try localBriefs()
        try attentionBudget()
        try meetingBriefs()
        print("PASS: kano improvements cover secure input/title/site exclusion, URL sanitizing, text saves, notes, keyless local models, offline review, resume, commitments, glance, budget, briefs and defaults")
    }

    // MARK: Privacy

    private static func privacyDecisions() throws {
        let engine = PrivacyEngine()
        var settings = PrivacySettings()
        try expect(!engine.decision(for: CaptureContext(bundleIdentifier: "x", secureInputActive: true), settings: settings).mayCapture, "安全输入时仍允许记录")
        settings.skipDuringSecureInput = false
        try expect(engine.decision(for: CaptureContext(bundleIdentifier: "x", secureInputActive: true), settings: settings).mayCapture, "关闭安全输入规则后仍被拦截")
        try expect(!engine.decision(for: CaptureContext(bundleIdentifier: "com.google.Chrome", windowTitle: "New Tab - Google Chrome (Incognito)"), settings: settings).mayCapture, "无痕窗口未被默认关键词排除")
        settings.excludedDomains = ["bank.example.com"]
        let chrome = "com.google.Chrome"
        try expect(!engine.decision(for: CaptureContext(bundleIdentifier: chrome, windowTitle: "Bank", pageURL: "https://login.bank.example.com/a?b=1"), settings: settings).mayCapture, "子域名未被排除")
        try expect(engine.decision(for: CaptureContext(bundleIdentifier: chrome, windowTitle: "Docs", pageURL: "https://notbank.example.com/"), settings: settings).mayCapture, "相似域名被误伤")
        try expect(!engine.decision(for: CaptureContext(bundleIdentifier: chrome, windowTitle: "Unknown"), settings: settings).mayCapture, "有排除网站时读不到网址应保守跳过")
        try expect(engine.decision(for: CaptureContext(bundleIdentifier: "com.apple.TextEdit", windowTitle: "Notes"), settings: settings).mayCapture, "非浏览器被网站规则拦截")
        settings.screenCapturePaused = true
        try expect(!engine.decision(for: CaptureContext(bundleIdentifier: "com.apple.TextEdit"), settings: settings).mayCapture, "暂停时仍允许记录")

        try expect(PrivacyEngine.sanitizedPageURL("https://user:pw@Example.com:8443/path/a?token=secret#frag") == "https://example.com/path/a", "网址未去除凭据、端口、查询和片段")
        try expect(PrivacyEngine.sanitizedPageURL("file:///Users/me/secret.txt") == nil && PrivacyEngine.sanitizedPageURL("javascript:alert(1)") == nil, "非网页地址被保存")
        try expect(PrivacyEngine.normalizedDomain("https://www.Example.com/x") == "www.example.com" && PrivacyEngine.normalizedDomain("*.example.com") == "example.com"
            && PrivacyEngine.normalizedDomain("localhost") == nil, "域名规范化错误")
    }

    private static func defaultsAndMigration() throws {
        let fresh = RecallState()
        try expect(!fresh.personaProfileSettings.enabled && fresh.personaProfileSettings.askedAt == nil, "新安装默认开启了关于我")
        try expect(!fresh.meetingBriefSettings.enabled && !fresh.privacy.recordPageAddress, "日历或网址默认开启")
        try expect(fresh.privacy.skipDuringSecureInput && !fresh.privacy.excludedTitleKeywords.isEmpty, "保护性默认值缺失")
        try expect(fresh.attentionSettings.dailyProactiveLimit == AttentionSettings.defaultDailyLimit, "通知额度默认值错误")
        // An archive written before these fields existed: persona was stored explicitly on, privacy had four keys.
        let legacy = #"{"schemaVersion":2,"privacy":{"excludedBundleIdentifiers":[],"cloudUseEnabled":true,"retainScreenshots":true,"screenCapturePaused":false},"personaProfileSettings":{"enabled":true,"personalizesResponses":true}}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(RecallState.self, from: Data(legacy.utf8))
        try expect(old.personaProfileSettings.enabled, "已有用户的关于我设置被静默改写")
        try expect(old.privacy.skipDuringSecureInput && old.privacy.excludedTitleKeywords == PrivacySettings.defaultExcludedTitleKeywords
            && old.privacy.excludedDomains.isEmpty && !old.privacy.recordPageAddress, "旧隐私设置未获得保护性默认值")
        try expect(old.reviewAttemptMetrics.isEmpty && old.attentionInbox.isEmpty, "旧存档解码新字段失败")
        let essentials = CaptureEventTemplate.allCases.filter(\.isEssential)
        try expect(essentials == [.manualMoment, .meetingSession, .taskCommitment], "常用模板不是三个")
        try expect(ReviewPeriodKind.stableCases == [.currentWeek, .previousWeek, .recentSeven], "稳定回顾范围错误")
    }

    // MARK: Capture

    @MainActor private final class Capturer: ScreenCapturing {
        var captured = 0
        func capture(scope: CaptureScope) async throws -> CapturePayload {
            captured += 1
            return CapturePayload(imageData: nil, sourceAppName: "Synthetic Browser", sourceBundleIdentifier: "com.google.Chrome", windowTitle: "Docs")
        }
        func requestScreenRecordingAccess() -> Bool { true }
        func currentTarget() -> CaptureTarget? { CaptureTarget(processID: 1, bundleIdentifier: "com.google.Chrome", appName: "Synthetic Browser") }
    }
    @MainActor private struct Reader: CaptureContextReading {
        var context: CaptureContext
        func context(for target: CaptureTarget?, settings: PrivacySettings) -> CaptureContext { context }
    }

    private static func fixture() throws -> (FileMemoryStore, RecallStorage) {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("kano-" + UUID().uuidString))
        return (try FileMemoryStore(storage: storage, credentials: InMemoryCredentialStore()), storage)
    }

    @MainActor private static func capturePreflight() async throws {
        let (store, storage) = try fixture(); defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        var rule = EventRule.defaults().first { $0.template == .manualMoment }!; rule.scope = .textOnly; rule.isEnabled = true
        let capturer = Capturer()
        let secure = CapturePipeline(store: store, storage: storage, screenCapturer: capturer,
            contextReader: Reader(context: CaptureContext(bundleIdentifier: "com.google.Chrome", windowTitle: "Docs", secureInputActive: true)))
        do { _ = try await secure.record(using: rule, userText: "合成内容"); throw Failure(errorDescription: "安全输入时仍保存了记录") }
        catch CapturePipelineError.captureExcluded { }
        try expect(capturer.captured == 0, "安全输入时仍读取了屏幕")

        var privacy = await store.snapshot().privacy; privacy.recordPageAddress = true; try await store.updatePrivacy(privacy)
        let withURL = CapturePipeline(store: store, storage: storage, screenCapturer: capturer,
            contextReader: Reader(context: CaptureContext(bundleIdentifier: "com.google.Chrome", windowTitle: "Docs", pageURL: "https://docs.example.com/a?id=42#x")))
        let saved = try await withURL.record(using: rule, userText: "合成网页记录：讨论发布流程")
        try expect(saved.pageURL == "https://docs.example.com/a", "网址未按设置去参保存")
        try expect(MemoryKnowledgeEngine.version(of: CaptureRecord(eventTemplate: .manualMoment, contentHash: "v", ocrText: "x"))
            == MemoryKnowledgeEngine.version(of: CaptureRecord(eventTemplate: .manualMoment, contentHash: "v2", ocrText: "x")), "新增可选字段改变了旧来源版本")
    }

    @MainActor private static func textSavesAndNotes() async throws {
        let (store, storage) = try fixture(); defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let pipeline = CapturePipeline(store: store, storage: storage)
        let record = try await pipeline.recordText("合成选中文字：发布前需要核对配置。联系 test@example.com", origin: .selectedText,
            sourceAppName: "Synthetic Editor", sourceBundleIdentifier: "test.editor")
        try expect(record.textOrigin == .selectedText && record.isRedacted && !record.ocrText.contains("test@example.com"), "选中文字未脱敏或来源错误")
        try expect(record.imageRelativePath == nil, "文字保存产生了截图")
        do { _ = try await pipeline.recordText("合成选中文字：发布前需要核对配置。联系 test@example.com", origin: .selectedText, sourceAppName: "Synthetic Editor", sourceBundleIdentifier: "test.editor")
            throw Failure(errorDescription: "重复文字未去重") } catch CapturePipelineError.duplicateCapture { }
        var privacy = await store.snapshot().privacy; privacy.excludedBundleIdentifiers.insert("test.secret"); try await store.updatePrivacy(privacy)
        do { _ = try await pipeline.recordText("另一段", origin: .selectedText, sourceAppName: "S", sourceBundleIdentifier: "test.secret")
            throw Failure(errorDescription: "排除应用的文字被保存") } catch CapturePipelineError.captureExcluded { }
        privacy.screenCapturePaused = true; try await store.updatePrivacy(privacy)
        do { _ = try await pipeline.recordText("暂停中的文字", origin: .selectedText, sourceAppName: "S", sourceBundleIdentifier: "test.editor")
            throw Failure(errorDescription: "暂停时文字被保存") } catch CapturePipelineError.captureExcluded { }
        privacy.screenCapturePaused = false; try await store.updatePrivacy(privacy)

        try await store.setCaptureNote(record.id, note: "  为季度汇报准备\n口径  ")
        var state = await store.snapshot()
        let noted = state.captures.first { $0.id == record.id }!
        try expect(noted.userNote == "为季度汇报准备 口径", "备注未整理为一行")
        try expect(noted.searchableText.contains("季度汇报"), "备注未进入可搜索文本")
        try expect(GlobalMemorySearch(state: state, matters: []).search("季度汇报").contains { $0.sourceIDs.contains(record.id) }, "全局搜索找不到备注")
        try expect(CaptureUnderstandingEngine.blocks(for: noted).contains { $0.speaker == .user && $0.text.contains("季度汇报") }, "备注未作为本人内容进入理解")
        try expect(CaptureUnderstandingEngine.blocks(for: noted).filter { !$0.text.hasPrefix("备注") }.allSatisfy { $0.speaker == .unknown }, "选中文字被当成本人发言")
        let before = CaptureUnderstandingEngine.sourceVersion(noted, in: state)
        try await store.setCaptureNote(record.id, note: nil)
        state = await store.snapshot()
        try expect(state.captures.first { $0.id == record.id }?.userNote == nil, "删除备注失败")
        try expect(CaptureUnderstandingEngine.sourceVersion(state.captures.first { $0.id == record.id }!, in: state) != before, "改备注未使派生结果失效")
        try expect(CapturePipeline.cleanNoteText("   ") == nil && CapturePipeline.cleanNoteText("密码: abc123")?.contains("abc123") == false, "备注空值或脱敏处理错误")
    }

    // MARK: Local models

    private static func localModelEndpoints() throws {
        let local = LLMConfiguration(provider: .openAICompatible, baseURLString: "http://localhost:11434/v1", model: "synthetic")
        try expect(local.isLocalEndpoint && local.hasCredential, "本机模型仍要求 API Key")
        _ = try ModelResponderFactory.make(configuration: local, credentials: InMemoryCredentialStore())
        let remote = LLMConfiguration(provider: .openAICompatible, baseURLString: "https://localhost.example.com/v1", model: "x")
        try expect(!remote.isLocalEndpoint && !remote.hasCredential, "远程地址被误认为本机")
        try expect(LLMConfiguration.isLoopback("http://127.0.0.1:1234/v1") && !LLMConfiguration.isLoopback("http://192.168.1.2/v1"), "回环地址判断错误")
        let list = #"{"data":[{"id":"nomic-embed-text"},{"id":"qwen3:8b"}]}"#
        try expect(LocalModelDiscovery.modelNames(from: Data(list.utf8)) == ["qwen3:8b", "nomic-embed-text"], "嵌入模型没有排在最后")
    }

    // MARK: Local briefs

    private static func record(_ text: String, app: String, title: String, at date: Date, note: String? = nil) -> CaptureRecord {
        var record = CaptureRecord(eventTemplate: .manualMoment, createdAt: date, sourceAppName: app, sourceBundleIdentifier: "test." + app,
            windowTitle: title, contentHash: UUID().uuidString, ocrText: text, summary: title, textOrigin: .userInput)
        record.userNote = note
        return record
    }

    private static func localBriefs() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now), yesterday = today.addingTimeInterval(-86_400 + 3_600)
        var state = RecallState(captures: [
            record("我需要明天提交季度预算表。", app: "Editor", title: "预算表", at: yesterday, note: "老板要的口径"),
            record("讨论发布流程与回滚方案。", app: "Browser", title: "发布流程文档", at: yesterday.addingTimeInterval(600)),
            record("讨论发布流程与回滚方案第二版。", app: "Browser", title: "发布流程文档", at: yesterday.addingTimeInterval(1_200))
        ])
        let day = LocalBriefing.offlineDay(yesterday, in: state)
        try expect(day.recordCount == 3 && day.groups.first?.app == "Browser" && day.groups.first?.count == 2, "离线回顾分组错误")
        try expect(day.notes.count == 1 && day.notes[0].text == "老板要的口径", "离线回顾缺少备注")
        try expect(day.actionLeads.contains { $0.title.contains("预算") }, "离线回顾缺少规则待办线索")
        try expect(state.reminders.isEmpty, "离线回顾自行创建了提醒")

        // No review for yesterday: the card asks to generate it instead of showing a raw record or window name.
        let resume = LocalBriefing.resume(in: state, matters: [])
        try expect(resume.count == 1 && resume[0].kind == .missingReview && calendar.isDate(resume[0].date, inSameDayAs: yesterday)
            && !resume.contains { $0.title == "发布流程文档" }, "没有回顾时，接着干仍展示原始记录")

        // With a review: only the user's own open items, worded by the review, newest mention of a topic deciding.
        let earlier = calendar.date(byAdding: .day, value: -1, to: yesterday)!
        func item(_ title: String, _ detail: String, status: String, owned: Bool = true, topic: String, kind: DailyItemKind = .matter) -> DailySummaryItem {
            DailySummaryItem(section: .progress, title: title, detail: detail, evidenceIDs: [state.captures[0].id],
                knowledge: DailyItemKnowledge(topic: topic, kind: kind, status: status, ownedByUser: owned, quotes: []))
        }
        state.dailySummaries = [
            DailySummary(day: earlier, content: "", sourceCaptureIDs: [state.captures[0].id], todos: [], generationKind: .cloud, items: [
                item("生产部署被叫停", "等 MFA 变更评审。", status: "blocked", topic: "生产部署"),
                item("研究股市走势", "提了一个问题。", status: "pending", topic: "股市研究")
            ]),
            DailySummary(day: yesterday, content: "", sourceCaptureIDs: [state.captures[0].id], todos: [], generationKind: .cloud, items: [
                item("一键发版已部署生产", "功能开关仍关闭。", status: "completed", topic: "生产部署"),
                item("ReAct 改造方案已写好但代码未改", "方案拆成三个 PR。之后再推进。", status: "pending", topic: "ReAct 改造"),
                item("消消乐改造特殊糖果", "按反馈调整。", status: "inProgress", owned: false, topic: "消消乐", kind: .reference)
            ])
        ]
        let open = LocalBriefing.resume(in: state, matters: [])
        let titles = open.map(\.title)
        try expect(titles.first == "ReAct 改造方案已写好但代码未改" && open.first?.detail == "待处理 · 方案拆成三个 PR", "接着干没有使用回顾事项的标题和详情")
        try expect(!titles.contains("生产部署被叫停"), "后来已完成的主题仍显示为受阻")
        try expect(titles.contains("研究股市走势") && !titles.contains("消消乐改造特殊糖果") && !titles.contains("一键发版已部署生产"),
                   "接着干混入了资料类、他人或已完成的事项")
        try expect(!open.contains { $0.kind == .missingReview }, "已有回顾仍提示生成")

        // Same matter present in both `items` (with topicID) and `ledger` (without topicID) must not duplicate in 接着干,
        // and a today review marking an earlier matter completed must close it immediately.
        var regTopic = Topic(title: "ReAct 改造方案升级", createdAt: yesterday, lastEventAt: yesterday)
        regTopic.aliases = ["ReAct 改造"]
        state.topicRegistry.upsert(regTopic)
        state.dailySummaries[1].items[1].knowledge?.topicID = regTopic.id
        state.dailySummaries[1].ledger = [
            DailyMatterLedgerEntry(topic: "ReAct 改造", kind: .matter, status: "pending", section: "progress",
                title: "ReAct 改造方案已写好但代码未改", detail: "方案拆成三个 PR。之后再推进。", ownedByUser: true, quotes: [], evidenceIDs: [state.captures[0].id], occurredAt: yesterday)
        ]
        let renamedMatter = MatterFile(id: "topic:" + regTopic.id.uuidString, title: "ReAct 改造方案升级", events: [
            MatterEvent(id: UUID(), title: "ReAct 改造方案升级", detail: "方案拆成三个 PR", recordedAt: yesterday, status: .pending, evidenceIDs: [state.captures[0].id])
        ])
        let deduped = LocalBriefing.resume(in: state, matters: [renamedMatter])
        try expect(deduped.filter { $0.title == "ReAct 改造方案已写好但代码未改" }.count == 1, "同一事项在 items 与 ledger 同时存在时在接着干中重复展示")
        try expect(deduped.first { $0.title == "ReAct 改造方案已写好但代码未改" }?.destination == .topic(renamedMatter.id), "改名/合并后的主题未能通过登记表别名关联到主题详情")

        state.dailySummaries.append(DailySummary(day: today, content: "", sourceCaptureIDs: [state.captures[0].id], todos: [], generationKind: .cloud, items: [
            item("股市研究已完成归档", "结论已整理。", status: "completed", topic: "股市研究")
        ]))
        let closedToday = LocalBriefing.resume(in: state, matters: [renamedMatter])
        try expect(!closedToday.contains { $0.title == "研究股市走势" }, "今天每日回顾已标记完成的事项仍停留在接着干")

        state.matterCorrections = [MatterCorrection(evidenceIDs: [state.captures[0].id], kind: .notMine)]
        try expect(LocalBriefing.resume(in: state, matters: []).allSatisfy { $0.kind != .openMatter }, "来源被更正为非本人后，事项仍出现在接着干")
        try expect(!LocalBriefing.offlineDay(yesterday, in: state).groups.flatMap(\.sourceIDs).contains(state.captures[0].id), "被更正为非本人的记录仍出现在简报")
        state.matterCorrections = []
        state.dailySummaries = []

        let related = LocalBriefing.related(title: "发布流程文档 - Browser", bundleIdentifier: "test.Browser", in: state)
        try expect(!related.isEmpty && related.allSatisfy { $0.windowTitle == "发布流程文档" }, "我上次怎么做的未找到同主题记录")
        try expect(LocalBriefing.related(title: "完全无关的标题", bundleIdentifier: nil, in: state).isEmpty, "无关标题返回了结果")

        // Week glance needs at least five records and says it counts records, not time.
        let start = calendar.date(byAdding: .day, value: -6, to: today)!
        let week = ReviewPeriod(start: start, end: today.addingTimeInterval(86_400))
        try expect(LocalBriefing.glance(week, in: state) == nil, "少于五条记录也给出统计")
        for i in 0..<4 { state.captures.append(record("合成 \(i)", app: "Browser", title: "页面 \(i)", at: yesterday.addingTimeInterval(Double(2_000 + i * 60)))) }
        let glance = try unwrap(LocalBriefing.glance(week, in: state), "统计缺失")
        try expect(glance.topApp == "Browser" && glance.recordCount == 7 && glance.sentence.contains("不代表时长"), "一句话统计内容错误")

        // Commitments come only from current understood facts and never from plain OCR.
        let chat = CaptureRecord(eventTemplate: .manualMoment, createdAt: yesterday, sourceAppName: "Chat", sourceBundleIdentifier: "test.chat",
            windowTitle: "项目群", contentHash: "c", ocrText: "[聊天·对方] 周五前给你接口文档\n[聊天·自己] 我明天把预算发你", textOrigin: .screenOCR)
        var withChat = RecallState(captures: [chat])
        try expect(LocalBriefing.commitments(in: withChat).isEmpty, "未经理解的文字被当作承诺")
        let version = CaptureUnderstandingEngine.sourceVersion(chat, in: withChat)
        // Built through Codable, the same way a saved archive is read.
        func fact(_ id: String, _ subject: String, speaker: String, actor: String) -> [String: Any] {
            ["id": id, "subject": subject, "detail": subject, "kind": "commitment", "speaker": speaker, "actor": actor, "status": "pending",
             "evidence": [["blockID": chat.id.uuidString + ":0:0", "quote": subject]]]
        }
        let json: [String: Any] = ["processorVersion": CaptureUnderstandingEngine.version, "sourceVersions": [chat.id.uuidString, version],
            "createdAt": ISO8601DateFormatter().string(from: .now), "coveredBlockCount": 2, "uncertainBlockCount": 0,
            "facts": [fact("a", "发送预算", speaker: "user", actor: "user"), fact("b", "提供接口文档", speaker: "other", actor: "other")]]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        withChat.captures[0].understanding = try decoder.decode(CaptureUnderstanding.self, from: JSONSerialization.data(withJSONObject: json))
        let commitments = LocalBriefing.commitments(in: withChat)
        try expect(commitments.contains { $0.direction == .iOwe && $0.title == "发送预算" }
            && commitments.contains { $0.direction == .owedToMe && $0.title == "提供接口文档" && $0.counterpart == "项目群" }, "往来承诺方向错误")

        let metrics = [ReviewAttemptMetric(kind: .daily, outcome: .succeeded, milliseconds: 4_000), ReviewAttemptMetric(kind: .daily, outcome: .failed, milliseconds: 9_000),
                       ReviewAttemptMetric(kind: .daily, outcome: .cancelled, milliseconds: 1_000), ReviewAttemptMetric(kind: .period, outcome: .partial, milliseconds: 20_000)]
        let stats = LocalBriefing.reviewStats(metrics, kind: .daily, since: .distantPast)
        try expect(stats.attempts == 3 && stats.successRate == 0.5 && stats.medianSeconds == 4, "回顾成功率统计错误（取消不计入分母）")
    }

    // MARK: Attention

    private static func attentionBudget() throws {
        var state = RecallState()
        state.attentionSettings.dailyProactiveLimit = 2
        let now = Date.now
        let notices = (0..<4).map { AttentionNotice(kind: .dailyReview, title: "t\($0)", body: "", dailyReviewID: UUID()) }
        let admitted = notices.map { AttentionBudget.admit($0, in: &state, now: now) }
        try expect(admitted == [true, true, false, false] && state.attentionInbox.count == 2, "每日主动通知上限未生效")
        try expect(AttentionBudget.admit(notices[0], in: &state, now: now.addingTimeInterval(86_400)), "新的一天没有重置额度")
        state.attentionSettings.dailyProactiveLimit = 0
        try expect(!AttentionBudget.admit(notices[1], in: &state, now: now.addingTimeInterval(2 * 86_400)), "上限为 0 时仍发送通知")
        for _ in 0..<40 { _ = AttentionBudget.admit(AttentionNotice(kind: .meetingBrief, title: "m", body: ""), in: &state, now: now) }
        try expect(state.attentionInbox.count == AttentionBudget.inboxLimit, "收件箱没有上限")
    }

    private static func meetingBriefs() throws {
        let now = Date.now
        var settings = MeetingBriefSettings(); settings.enabled = true; settings.minutesBefore = 10
        let soon = CalendarEventSummary(key: "e1", title: "预算评审", start: now.addingTimeInterval(300), attendees: ["Alex"])
        let later = CalendarEventSummary(key: "e2", title: "周会", start: now.addingTimeInterval(3_600))
        try expect(MeetingBriefEngine.due([soon, later], settings: settings, now: now).map(\.key) == ["e1"], "会前时间窗计算错误")
        settings.briefedEventKeys = ["e1"]
        try expect(MeetingBriefEngine.due([soon], settings: settings, now: now).isEmpty, "同一会议被重复简报")
        let state = RecallState(captures: [record("预算评审材料：第三季度。", app: "Editor", title: "预算", at: now.addingTimeInterval(-3_600)),
                                           record("与 Alex 讨论接口。", app: "Chat", title: "接口", at: now.addingTimeInterval(-7_200)),
                                           record("无关内容。", app: "Editor", title: "杂项", at: now.addingTimeInterval(-9_000))])
        let brief = MeetingBriefEngine.brief(for: soon, in: state)
        try expect(brief.records.count == 2 && !brief.records.contains { $0.windowTitle == "杂项" }, "会前简报匹配错误")
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(errorDescription: message) }
        return value
    }
}
